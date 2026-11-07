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

module BlockfrostHttp (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import Cometa.Error (Error (..))
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Blockfrost as Blockfrost
import qualified Cometa.Provider.Blockfrost.Internal.Config as Config
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import Control.Concurrent (forkFinally, killThread, threadDelay, yield)
import Control.Concurrent.MVar (modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryTakeMVar)
import Control.Exception (AsyncException (ThreadKilled), bracket, finally, fromException)
import Control.Monad (forM_, forever, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Char (toLower)
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (isNothing)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Network.HTTP.Types.URI as URI
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- TYPES ----------------------------------------------------------------------

data WireRequest = WireRequest
  { requestLine :: !ByteString,
    requestHeaders :: ![ByteString],
    requestBody :: !ByteString
  }
  deriving (Show)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Blockfrost HTTP transport"
    [ testCase "opaque credentials and bounded schedules reject unsafe input" configuration,
      testCase "public provider uses custom base paths with optional credentials" customEndpoints,
      testCase "custom endpoint queries survive pagination and selected network magic" endpointQueries,
      testCase "invalid URLs fail before callback without echoing secrets" invalidEndpoints,
      testCase "IPv6 and explicit ports validate without live requests" endpointSyntax,
      testCase "path/query encoding, credential header and exact CBOR body" wire,
      testCase "HTTP failures retain status without redirects or retries" statuses,
      testCase "whole-request timeout and body-size limits release response scope" limits,
      testCase "asynchronous cancellation propagates and later requests recover" cancellation,
      testCase "escaped transports close and scope teardown joins active sends" lifetime
    ]

config :: IO Config.Config
config = Config.defaultConfig Config.Preview . Just <$> require (Config.mkProjectId "fixture-project-id")

request :: Http.Request
request = Http.Request Http.Get ["health"] [] B.empty B.empty Nothing

configuration :: IO ()
configuration = do
  forM_ ["", "secret\r\nproject_id: leaked", "secret value"] $ \value ->
    assertBool "invalid credential rejected" (isLeft (Config.mkProjectId value))
  configured <- config
  forM_ [0, -1, 60001, maxBound] $ \duration -> do
    assertBool "invalid HTTP timeout" (isLeft (Config.validateConfig configured {Config.responseTimeoutMillis = duration}))
    assertBool "invalid poll interval" (isLeft (Config.validateConfig configured {Config.pollIntervalMillis = duration}))

-- Exercise custom HTTP through the public provider, with the same validation,
-- scope, URL joining and authentication path used by applications.
customEndpoints :: IO ()
customEndpoints = do
  credential <- require (Blockfrost.mkProjectId "fixture-project-id")
  destination <- require (Address.fromBytes (B.cons 0x60 (B.replicate 28 1)))
  forM_ [Nothing, Just credential] $ \project ->
    forM_ ["", "/", "///"] $ \trailing -> do
      received <- newEmptyMVar
      withServer (\incoming -> putMVar received incoming >> pure (response 200 "[]" [])) $ \base -> do
        let configured = (Blockfrost.defaultConfig Blockfrost.Mainnet project) {Blockfrost.endpoint = Text.pack base <> "/custom%20prefix" <> trailing}
        outcome <- Blockfrost.withProvider configured $ \provider -> do
          Provider.networkMagic provider @?= 764824073
          Provider.utxosAt provider destination
        fmap length outcome @?= Right 0
        actual <- takeMVar received
        let (actualPath, _) = B.break (== 63) (B.takeWhile (/= 32) (B.drop 4 (requestLine actual)))
        let separator = Text.encodeUtf8 (if Text.null trailing then "/" else trailing)
        actualPath @?= "/api/v0/custom%20prefix" <> separator <> "addresses/" <> Text.encodeUtf8 (Address.toText destination) <> "/utxos"
        let authorization = filter (\header -> "project_id:" `B.isPrefixOf` lower header) (requestHeaders actual)
        authorization @?= case project of Nothing -> []; Just _ -> ["project_id: fixture-project-id"]
  where
    lower = C.map toLower

endpointQueries :: IO ()
endpointQueries = do
  destination <- require (Address.fromBytes (B.cons 0x60 (B.replicate 28 1)))
  forM_ [(Blockfrost.Mainnet, 764824073), (Blockfrost.Preprod, 1), (Blockfrost.Preview, 2)] $ \(selected, magic) -> do
    received <- newEmptyMVar
    withServer (\incoming -> putMVar received incoming >> pure (response 200 "[]" [])) $ \base -> do
      let configured = (Blockfrost.defaultConfig selected Nothing) {Blockfrost.endpoint = Text.pack base <> "/proxy/?tenant=space%20value&auth=fixture-route-key&count=7&page=999&order=desc"}
      outcome <- Blockfrost.withProvider configured $ \provider -> do
        Provider.networkMagic provider @?= magic
        Provider.utxosAt provider destination
      fmap length outcome @?= Right 0
      actual <- takeMVar received
      let target = B.takeWhile (/= 32) (B.drop 4 (requestLine actual))
          (_, suffix) = B.break (== 63) target
          parameters = URI.parseQuery suffix
      lookup "tenant" parameters @?= Just (Just "space value")
      lookup "auth" parameters @?= Just (Just "fixture-route-key")
      forM_ [("count", "100"), ("page", "1"), ("order", "asc")] $ \(key, value) -> do
        filter ((== key) . fst) parameters @?= [(key, Just value)]
      assertBool "optional project header omitted" (not (any ("project_id:" `B.isPrefixOf`) (requestHeaders actual)))

invalidEndpoints :: IO ()
invalidEndpoints = do
  forM_
    [ "",
      "/relative/api",
      "ftp://host/api?auth=fixture-secret",
      "https://",
      "https:///missing-host",
      "http://host:0/api",
      "http://host:/api",
      "http://host:65536/api",
      "http://host:18446744073709551617/api",
      "http://host:999999999999999999999999999999999999999/api",
      "http://host:-1/api",
      "http://host:not-a-port/api",
      "http://user:fixture-secret@host/api",
      "http://@host/api",
      "https://host/api#fixture-secret",
      "http://host/has space",
      "http://host/\r\nproject_id: fixture-secret",
      "http://::1:3000/api"
    ]
    $ \endpoint -> do
      called <- newIORef False
      let configured = (Blockfrost.defaultConfig Blockfrost.Preview Nothing) {Blockfrost.endpoint = endpoint}
      outcome <- Blockfrost.withProvider configured (\_ -> writeIORef called True >> pure (Right ()))
      case outcome of
        Left (InvalidProviderConfiguration detail) -> assertBool "diagnostic excludes URL/credentials" (not ("fixture-secret" `Text.isInfixOf` detail))
        other -> assertFailure (show other)
      readIORef called >>= (@?= False)

endpointSyntax :: IO ()
endpointSyntax = do
  forM_
    [ "http://localhost:1/api",
      "HTTP://localhost:00080/api",
      "https://localhost:65535/api/",
      "http://[::1]:3000/api/v0",
      "https://[2001:db8::1]:8443/custom%20prefix?tenant=fixture",
      "http://127.0.0.1/api/v0?route=fixture"
    ]
    $ \endpoint ->
      Config.validateConfig (Blockfrost.defaultConfig Blockfrost.Preprod Nothing) {Blockfrost.endpoint = endpoint} @?= Right ()

wire :: IO ()
wire = do
  received <- newEmptyMVar
  configured <- config
  withServer (\incoming -> putMVar received incoming >> pure (response 200 "ok" [])) $ \endpoint ->
    Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport -> do
      result <- Http.send transport request {Http.method = Http.Post, Http.path = ["tx", "part/with ?"], Http.query = [("page", "2"), ("asset", "space value")], Http.body = B.pack [0, 255, 128], Http.contentType = "application/cbor"}
      fmap Http.status result @?= Right 200
      actual <- takeMVar received
      requestLine actual @?= "POST /api/v0/tx/part%2Fwith%20%3F?page=2&asset=space%20value HTTP/1.1"
      assertBool "project credential sent only as header" ("project_id: fixture-project-id" `elem` requestHeaders actual)
      assertBool "content type" ("Content-Type: application/cbor" `elem` requestHeaders actual)
      requestBody actual @?= B.pack [0, 255, 128]

statuses :: IO ()
statuses = do
  configured <- config
  calls <- newMVar (0 :: Int)
  withServer (\_ -> modifyMVar_ calls (pure . (+ 1)) >> pure (response 429 "credential-echo-must-not-be-diagnostic" [("Retry-After", "2"), ("Location", "/other")])) $ \endpoint ->
    Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport -> do
      result <- Http.send transport request
      fmap (\reply -> (Http.status reply, Http.retryAfter reply)) result @?= Right (429, Just "2")
      readMVar calls >>= (@?= 1)
  redirectCalls <- newMVar (0 :: Int)
  withServer (\_ -> modifyMVar_ redirectCalls (pure . (+ 1)) >> pure (response 302 B.empty [("Location", "/other")])) $ \endpoint ->
    Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport -> do
      Http.send transport request >>= (@?= Right 302) . fmap Http.status
      readMVar redirectCalls >>= (@?= 1)
  submissionCalls <- newMVar (0 :: Int)
  withServer (\_ -> modifyMVar_ submissionCalls (pure . (+ 1)) >> pure "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n") $ \endpoint ->
    Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport -> do
      result <- Http.send transport request {Http.method = Http.Post, Http.path = ["tx", "submit"], Http.body = "exact-transaction", Http.contentType = "application/cbor"}
      result @?= Left Http.ConnectionFailure
      assertBool "transport diagnostics cannot echo credential or body" (not ("fixture-project-id" `C.isInfixOf` C.pack (show result)) && not ("exact-transaction" `C.isInfixOf` C.pack (show result)))
      readMVar submissionCalls >>= (@?= 1)

limits :: IO ()
limits = do
  configured <- config
  withServer (\_ -> threadDelay 150000 >> pure (response 200 "late" [])) $ \endpoint ->
    Http.withTransport configured {Config.endpoint = Text.pack endpoint, Config.responseTimeoutMillis = 25} $ \transport ->
      Http.send transport request {Http.requestTimeoutMillis = Just 1000} >>= (@?= Left Http.Timeout)
  withServer (\_ -> threadDelay 150000 >> pure (response 200 "late" [])) $ \endpoint ->
    Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport ->
      Http.send transport request {Http.requestTimeoutMillis = Just 25} >>= (@?= Left Http.Timeout)
  withServer (\_ -> pure (response 200 (B.replicate (Http.maximumResponseBytes + 1) 120) [])) $ \endpoint ->
    Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport ->
      Http.send transport request >>= (@?= Left Http.ResponseTooLarge)

cancellation :: IO ()
cancellation = do
  configured <- config
  started <- newEmptyMVar
  gate <- newEmptyMVar
  let handler incoming =
        if requestLine incoming == "GET /api/v0/blocked HTTP/1.1"
          then putMVar started () >> takeMVar gate >> pure (response 200 "late" [])
          else pure (response 200 "recovered" [])
  withServer handler $ \endpoint ->
    Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport -> do
      finished <- newEmptyMVar
      worker <- forkFinally (Http.send transport request {Http.path = ["blocked"]}) (putMVar finished)
      ( do
          within (takeMVar started)
          killThread worker
          outcome <- within (takeMVar finished)
          case outcome of
            Left failure -> fromException failure @?= Just ThreadKilled
            Right _ -> assertFailure "asynchronous cancellation became an expected HTTP failure"
          Http.send transport request >>= (@?= Right 200) . fmap Http.status
        )
        `finally` void (tryPutMVar gate ())

lifetime :: IO ()
lifetime = do
  configured <- config
  started <- newEmptyMVar
  gate <- newEmptyMVar
  finished <- newEmptyMVar
  escaped <- newEmptyMVar
  workerResult <- newEmptyMVar
  let handler _ = putMVar started () >> takeMVar gate >> pure (response 200 "done" [])
  withServer handler $ \endpoint -> do
    owner <-
      forkFinally
        ( Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport -> do
            putMVar escaped transport
            _ <- forkFinally (Http.send transport request) (putMVar workerResult)
            within (readMVar started)
        )
        (putMVar finished)
    ( do
        transport <- within (takeMVar escaped)
        within (readMVar started)
        -- Scope exit has invalidated new work, but must wait for the old response.
        within (waitClosed transport)
        tryTakeMVar finished >>= assertBool "scope joins in-flight send" . isNothing
        Http.send transport request >>= (@?= Left Http.Closed)
        putMVar gate ()
        outcome <- within (takeMVar workerResult)
        either (assertFailure . show) (\result -> fmap Http.status result @?= Right 200) outcome
        within (takeMVar finished) >>= either (assertFailure . show) pure
        closedAgain <- Http.checkOpen transport
        closedAgain @?= Left Http.Closed
        Http.send transport request >>= (@?= Left Http.Closed)
      )
      `finally` (void (tryPutMVar gate ()) >> killThread owner)

waitClosed :: Http.Transport -> IO ()
waitClosed transport = do
  state <- Http.checkOpen transport
  case state of
    Left Http.Closed -> pure ()
    Left failure -> assertFailure (show failure)
    Right () -> yield >> waitClosed transport

-- A local HTTP fixture owns its listener, accept worker and every connection
-- worker. No public endpoint is contacted, and only a fixed fake project ID is used.
withServer :: (WireRequest -> IO ByteString) -> (String -> IO a) -> IO a
withServer handler action = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure value
    _ -> assertFailure "unexpected fixture socket family" >> fail "fixture"
  workers <- newMVar []
  bracket (forkFinally (acceptLoop listener workers) (const (pure ()))) (stop workers) $ \_ ->
    action ("http://127.0.0.1:" <> show port <> "/api/v0")
  where
    open = do
      listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
      Socket.setSocketOption listener Socket.ReuseAddr 1
      Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
      Socket.listen listener 8
      pure listener
    acceptLoop listener workers = forever $ do
      (connection, _) <- Socket.accept listener
      worker <- forkFinally (receive connection >>= handler >>= Socket.sendAll connection) (const (Socket.close connection))
      modifyMVar_ workers (pure . (worker :))
    stop workers acceptWorker = do
      killThread acceptWorker
      readMVar workers >>= mapM_ killThread

receive :: Socket.Socket -> IO WireRequest
receive connection = do
  (headers, rest) <- headerBytes B.empty
  let lines' = C.split '\n' (B.filter (/= 13) headers)
      line = case lines' of [] -> B.empty; value : _ -> value
      fields = drop 1 lines'
      lengthHeader = find ("Content-Length:" `B.isPrefixOf`) fields
      size = case lengthHeader >>= C.readInt . C.dropWhile (== ' ') . B.drop 15 of Just (value, _) -> value; Nothing -> 0
  bytes <- remainingBytes size rest
  pure (WireRequest line fields bytes)
  where
    headerBytes accumulated = do
      let (prefix, suffix) = B.breakSubstring "\r\n\r\n" accumulated
      if not (B.null suffix)
        then pure (prefix, B.drop 4 suffix)
        else do
          chunk <- Socket.recv connection 4096
          if B.null chunk || B.length accumulated > 65536 then fail "incomplete fixture headers" else headerBytes (accumulated <> chunk)
    remainingBytes size accumulated
      | B.length accumulated >= size = pure (B.take size accumulated)
      | otherwise = do
          chunk <- Socket.recv connection 4096
          if B.null chunk then fail "incomplete fixture body" else remainingBytes size (accumulated <> chunk)

response :: Int -> ByteString -> [(ByteString, ByteString)] -> ByteString
response code bytes headers =
  "HTTP/1.1 "
    <> C.pack (show code)
    <> " Fixture\r\nContent-Length: "
    <> C.pack (show (B.length bytes))
    <> "\r\nConnection: close\r\n"
    <> B.concat [key <> ": " <> value <> "\r\n" | (key, value) <- headers]
    <> "\r\n"
    <> bytes

require :: (Show failure) => Either failure value -> IO value
require = either (\failure -> assertFailure (show failure) >> fail "invalid fixture") pure

within :: IO a -> IO a
within action = do
  result <- timeout 2000000 action
  maybe (assertFailure "local HTTP fixture timed out" >> fail "fixture timeout") pure result
