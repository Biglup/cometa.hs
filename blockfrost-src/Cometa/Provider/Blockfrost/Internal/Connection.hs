-- Copyright 2026 Biglup Labs
-- SPDX-License-Identifier: Apache-2.0
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_HADDOCK hide #-}

-- | HTTP and TLS connections with joined cancellation of Windows socket I/O.
module Cometa.Provider.Blockfrost.Internal.Connection (managerSettings, managerSettingsWithStore, socketBackend) where

-- IMPORTS --------------------------------------------------------------------

import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (forConcurrently, withAsync)
import Control.Concurrent.MVar (tryPutMVar, tryTakeMVar)
import Control.Concurrent.STM (retry)
import Control.Exception (IOException, bracketOnError, mask, onException, throwIO, try)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as Lazy
import Data.List (find)
import Data.Void (Void, absurd)
import Data.X509.CertificateStore (CertificateStore)
import qualified Network.HTTP.Client as Http
import qualified Network.HTTP.Client.Internal as HttpConnection
import qualified Network.HTTP.Client.TLS as TLS
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import qualified Network.TLS as Tls
import qualified Network.TLS.Extra.Cipher as Cipher
import System.X509 (getSystemCertificateStore)

-- DEFINITIONS ----------------------------------------------------------------

-- http-client's default plain socket reads, and tls's Socket backend reads,
-- block in safe FFI calls on Windows. An async exception cannot reach them.
-- Keep http-client's connection/proxy and TLS validation contracts, replacing
-- only the backend socket reads/writes with operations that cancel and JOIN
-- their own OVERLAPPED I/O before propagating an exception.
managerSettings :: IO Http.ManagerSettings
managerSettings = managerSettingsWithStore <$> getSystemCertificateStore

-- The injectable trust store is private and used only by deterministic TLS tests.
-- Every certificate and hostname check still runs through tls's default hooks.
managerSettingsWithStore :: CertificateStore -> Http.ManagerSettings
managerSettingsWithStore certificates =
  let parameters :: String -> Int -> Tls.ClientParams
      parameters host port =
        let defaults = Tls.defaultParamsClient (Http.strippedHostName host) (C.pack (show port))
         in defaults
              { Tls.clientSupported = Tls.defaultSupported {Tls.supportedCiphers = Cipher.ciphersuite_default},
                Tls.clientShared = (Tls.clientShared defaults) {Tls.sharedCAStore = certificates}
              }
      secure address host port =
        bracketOnError (rawConnection address host port) HttpConnection.connectionClose (secureConnection (parameters host port))
      proxy connectBytes checkConnection serverName address host port =
        bracketOnError (rawConnection address host port) HttpConnection.connectionClose $ \connection -> do
          HttpConnection.connectionWrite connection connectBytes
          void (checkConnection connection)
          targetPort <- proxyTargetPort connectBytes
          secureConnection (parameters serverName targetPort) connection
   in TLS.tlsManagerSettings
        { Http.managerRawConnection = pure rawConnection,
          Http.managerTlsConnection = pure secure,
          HttpConnection.managerTlsProxyConnection = pure proxy,
          Http.managerRetryableException = const False,
          -- closeManager is a deprecated no-op. With no idle sockets, response
          -- scopes close their connections without needing a manager GC cycle.
          Http.managerIdleConnectionCount = 0
        }

rawConnection :: Maybe Socket.HostAddress -> String -> Int -> IO HttpConnection.Connection
rawConnection address host port =
  bracketOnError (connectSocket address host port) Socket.close socketConnection

socketConnection :: Socket.Socket -> IO HttpConnection.Connection
socketConnection socket =
  Http.makeConnection
    (completed (Socket.recvWith socket 8192 retry))
    (\bytes -> completed (Socket.sendAllWith socket bytes retry))
    (Socket.close socket)

-- Preserve http-client's staggered parallel address attempts. Each attempt owns
-- its socket until it publishes the winner; cancelled/losing attempts close it.
connectSocket :: Maybe Socket.HostAddress -> String -> Int -> IO Socket.Socket
connectSocket address host port = do
  addresses <- case address of
    Just ipv4 -> pure [Socket.defaultHints {Socket.addrFamily = Socket.AF_INET, Socket.addrSocketType = Socket.Stream, Socket.addrAddress = Socket.SockAddrInet (fromIntegral port) ipv4}]
    Nothing -> resolve host port
  mask $ \restore -> do
    result <- newEmptyMVar
    let attempt (info, delay) = mask $ \restoreAttempt -> do
          socket <- try (threadDelay delay >> open restoreAttempt info)
          case socket of
            Left failure -> pure (Just (failure :: IOException))
            Right connected -> do
              published <- tryPutMVar result (Right connected)
              unless published (Socket.close connected)
              pure Nothing
        run = do
          failures <- forConcurrently (zip addresses [0, 250000 ..]) attempt
          case find isFailure failures of
            Just (Just failure) -> void (tryPutMVar result (Left failure))
            _ -> pure ()
        abandon = do
          pending <- tryTakeMVar result
          case pending of
            Just (Right socket) -> Socket.close socket
            _ -> pure ()
    winner <- withAsync (restore run) (const (takeMVar result)) `onException` abandon
    either throwIO pure winner
  where
    isFailure Nothing = False
    isFailure (Just _) = True
    open restoreConnect info = bracketOnError (Socket.socket (Socket.addrFamily info) Socket.Stream (Socket.addrProtocol info)) Socket.close $ \socket -> do
      _ <- restoreConnect $ do
        Socket.setSocketOption socket Socket.NoDelay 1
        completed (Socket.connectWith socket (Socket.addrAddress info) retry)
      pure socket

-- getaddrinfo is itself a noninterruptible foreign call on Windows. Its worker
-- owns all temporary resolver buffers and no connection or request-body state.
-- A cancelled caller stops waiting immediately; the OS lookup frees its own
-- buffers when it returns. Killing and joining that worker would defeat the
-- whole-request DNS deadline before any socket had even been acquired.
resolve :: String -> Int -> IO [Socket.AddrInfo]
resolve host port = do
  result <- newEmptyMVar
  _ <- forkFinally (Socket.getAddrInfo (Just Socket.defaultHints {Socket.addrSocketType = Socket.Stream}) (Just (Http.strippedHostName host)) (Just (show port))) (putMVar result)
  addresses <- takeMVar result >>= either throwIO pure
  if null addresses then ioError (userError "HTTP destination has no addresses") else pure addresses

proxyTargetPort :: ByteString -> IO Int
proxyTargetPort request = case C.words (C.takeWhile (/= '\r') request) of
  ["CONNECT", authority, "HTTP/1.1"] -> case C.readInt (snd (C.breakEnd (== ':') authority)) of
    Just (port, rest) | B.null rest && port > 0 && port <= 65535 -> pure port
    _ -> invalid
  _ -> invalid
  where
    invalid = ioError (userError "Invalid HTTP proxy CONNECT authority")

completed :: IO (Either Void a) -> IO a
completed operation = do
  result <- operation
  case result of
    Left impossible -> absurd impossible
    Right value -> pure value

secureConnection :: Tls.ClientParams -> HttpConnection.Connection -> IO HttpConnection.Connection
secureConnection parameters connection =
  bracketOnError (Tls.contextNew backend parameters) Tls.contextClose $ \context -> do
    Tls.handshake context
    Http.makeConnection
      (Tls.recvData context)
      (Tls.sendData context . Lazy.fromStrict)
      (Tls.contextClose context)
  where
    backend = connectionBackend connection

-- No close-notify write is attempted during cleanup: an aborted peer may not be
-- reading and cleanup runs masked, after the request's timeout has already fired.
-- Closing joins all in-flight backend I/O first and never starts another write.
socketBackend :: Socket.Socket -> IO Tls.Backend
socketBackend socket = connectionBackend <$> socketConnection socket

connectionBackend :: HttpConnection.Connection -> Tls.Backend
connectionBackend connection =
  Tls.Backend
    { Tls.backendFlush = pure (),
      Tls.backendClose = HttpConnection.connectionClose connection,
      Tls.backendSend = HttpConnection.connectionWrite connection,
      Tls.backendRecv = receiveExactly connection
    }

-- TLS needs exactly the requested record bytes. Retaining http-client's unread
-- stack also preserves any bytes buffered while checking an HTTP CONNECT reply.
receiveExactly :: HttpConnection.Connection -> Int -> IO ByteString
receiveExactly connection count = go count []
  where
    go 0 chunks = pure (B.concat (reverse chunks))
    go remaining chunks = do
      bytes <- HttpConnection.connectionRead connection
      if B.null bytes
        then pure (B.concat (reverse chunks))
        else do
          let (wanted, rest) = B.splitAt remaining bytes
          unless (B.null rest) (HttpConnection.connectionUnread connection rest)
          go (remaining - B.length wanted) (wanted : chunks)
