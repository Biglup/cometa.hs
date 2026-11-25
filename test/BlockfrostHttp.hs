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
import qualified Cometa.Provider.Blockfrost.Internal.Connection as Connection
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import Control.Concurrent (forkFinally, killThread, threadDelay, yield)
import Control.Concurrent.MVar (modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryTakeMVar)
import Control.Concurrent.STM (STM, atomically, check, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), IOException, SomeException, bracket, bracketOnError, catch, finally, fromException, mask, onException, throwIO, try)
import Control.Monad (forM_, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as Lazy
import Data.Char (toLower)
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (isNothing)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.X509.CertificateStore as Certificates
import qualified Data.X509.Memory as Certificates
import qualified Network.HTTP.Client as Client
import qualified Network.HTTP.Types.URI as URI
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import qualified Network.TLS as Tls
import qualified Network.TLS.Extra.Cipher as Cipher
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
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
      testCase "fixture cleanup joins an idle listener without a client" fixtureCleanup,
      testCase "fixture cleanup joins an incomplete request and blocked handler" fixtureConnections,
      testCase "fixture cleanup preserves continuation exceptions" fixtureException,
      testCase "fixture cleanup deadline reports failure while cleanup retains ownership" fixtureDeadline,
      testCase "public provider uses custom base paths with optional credentials" customEndpoints,
      testCase "custom endpoint queries survive pagination and selected network magic" endpointQueries,
      testCase "invalid URLs fail before callback without echoing secrets" invalidEndpoints,
      testCase "IPv6 and explicit ports validate without live requests" endpointSyntax,
      testCase "path/query encoding, credential header and exact CBOR body" wire,
      testCase "HTTP failures retain status without redirects or retries" statuses,
      testCase "whole-request timeout and body-size limits release response scope" limits,
      testCase "asynchronous cancellation propagates and later requests recover" cancellation,
      testCase "TLS validates trusted roots and rejects untrusted or mismatched hosts" tlsValidation,
      testCase "TLS blocked-read cancellation propagates and later requests recover" tlsCancellation,
      testCase "TLS cancellation joins blocked writes without a close-notify write" tlsWriteCancellation,
      testCase "TLS handshake timeout cancels its socket operations" tlsHandshakeTimeout,
      testCase "TLS CONNECT proxy retains target hostname verification" tlsProxy,
      testCase "refused local connections obey request deadlines and close their scope" refusedConnection,
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
cancellation = cancellationScenario withServer $ \configured endpoint ->
  Http.withTransport configured {Config.endpoint = Text.pack endpoint}

tlsCancellation :: IO ()
tlsCancellation = do
  let settings = Connection.managerSettingsWithStore fixtureRoots
  cancellationScenario withTlsServer $ \configured endpoint ->
    Http.withEndpointSettings (pure settings) configured (tlsEndpoint endpoint)

cancellationScenario :: ((WireRequest -> IO ByteString) -> (String -> IO ()) -> IO ()) -> (Config.Config -> String -> (Http.Transport -> IO ()) -> IO ()) -> IO ()
cancellationScenario server transportScope = do
  configured <- config
  started <- newEmptyMVar
  gate <- newEmptyMVar
  let handler incoming =
        if requestLine incoming == "GET /api/v0/blocked HTTP/1.1"
          then putMVar started () >> takeMVar gate >> pure (response 200 "late" [])
          else pure (response 200 "recovered" [])
  server handler $ \endpoint -> cleanupWithin $
    transportScope configured endpoint $ \transport -> do
      finished <- newEmptyMVar
      worker <- forkFinally (Http.send transport request {Http.path = ["blocked"]}) (putMVar finished)
      ( do
          within (takeMVar started)
          traceFixture "cancellation requesting ThreadKilled while response is withheld"
          killThread worker
          outcome <- within (takeMVar finished)
          case outcome of
            Left failure -> fromException failure @?= Just ThreadKilled
            Right _ -> assertFailure "asynchronous cancellation became an expected HTTP failure"
          traceFixture "cancellation joined; sending recovery request on same transport"
          Http.send transport request >>= (@?= Right 200) . fmap Http.status
        )
        `finally` void (tryPutMVar gate ())

tlsValidation :: IO ()
tlsValidation = do
  configured <- config
  let trusted = Connection.managerSettingsWithStore fixtureRoots
      untrusted = Connection.managerSettingsWithStore (Certificates.makeCertificateStore [])
  forM_ [(trusted, False, Right 200), (untrusted, False, Left Http.ConnectionFailure), (trusted, True, Left Http.ConnectionFailure)] $ \(settings, wrongHost, expected) ->
    withTlsServer (\_ -> pure (response 200 "trusted" [])) $ \endpoint -> do
      let target = if wrongHost then "https://127.0.0.1:" <> drop (length ("https://localhost:" :: String)) (tlsEndpoint endpoint) else tlsEndpoint endpoint
      cleanupWithin $ Http.withEndpointSettings (pure settings) configured target $ \transport ->
        Http.send transport request >>= (@?= expected) . fmap Http.status

tlsWriteCancellation :: IO ()
tlsWriteCancellation = do
  configured <- config
  started <- newEmptyMVar
  gate <- newEmptyMVar
  let peer socket _ = withTlsContext socket $ \_ -> putMVar started () >> takeMVar gate
  withSocketServer (pure ()) peer $ \endpoint -> cleanupWithin $
    Http.withEndpointSettings (pure (Connection.managerSettingsWithStore fixtureRoots)) configured (tlsEndpoint endpoint) $ \transport -> do
      finished <- newEmptyMVar
      worker <- forkFinally (Http.send transport request {Http.method = Http.Post, Http.body = B.replicate (8 * 1024 * 1024) 7}) (putMVar finished)
      within (takeMVar started)
      -- The peer has completed TLS but does not consume any HTTP/application
      -- bytes. A payload larger than normal TCP buffers exercises backend writes.
      threadDelay 50000
      killThread worker
      outcome <- within (takeMVar finished)
      case outcome of
        Left failure -> fromException failure @?= Just ThreadKilled
        Right result -> assertFailure ("blocked TLS write returned before cancellation: " <> show result)

tlsHandshakeTimeout :: IO ()
tlsHandshakeTimeout = do
  configured <- config
  gate <- newEmptyMVar
  -- A TCP peer accepts the connection but never sends any TLS handshake bytes.
  withSocketServer (pure ()) (\_ _ -> takeMVar gate) $ \endpoint ->
    cleanupWithin $ Http.withEndpointSettings (pure (Connection.managerSettingsWithStore fixtureRoots)) configured {Config.responseTimeoutMillis = 50} (tlsEndpoint endpoint) $ \transport ->
      Http.send transport request >>= (@?= Left Http.Timeout)

tlsProxy :: IO ()
tlsProxy = do
  configured <- config
  connected <- newEmptyMVar
  withSocketServer (pure ()) (proxyConnection connected) $ \endpoint -> do
    port <- endpointPort endpoint
    let settings = Client.managerSetSecureProxy (Client.useProxy (Client.Proxy "127.0.0.1" (fromIntegral port))) (Connection.managerSettingsWithStore fixtureRoots)
    cleanupWithin $ Http.withEndpointSettings (pure settings) configured "https://localhost:443/api/v0" $ \transport ->
      Http.send transport request >>= (@?= Right 200) . fmap Http.status
    within (takeMVar connected) >>= (@?= "CONNECT localhost:443 HTTP/1.1")
  where
    proxyConnection connected socket cancelled = do
      connectRequest <- receive socket cancelled
      putMVar connected (requestLine connectRequest)
      Socket.sendAll socket "HTTP/1.1 200 Connection established\r\n\r\n"
      serveTls (\_ -> pure (response 200 "proxied" [])) socket cancelled

refusedConnection :: IO ()
refusedConnection = Socket.withSocketsDo $ do
  configured <- config
  address <- bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \socket -> do
    Socket.bind socket (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.getSocketName socket
  case address of
    Socket.SockAddrInet port _ -> do
      escaped <- newEmptyMVar
      -- Windows can retry loopback SYNs for about two seconds before reporting
      -- refusal. Bound the request explicitly: either refusal or its earlier
      -- deadline is correct, while the unchanged fixture deadline still detects
      -- a connect/cancellation operation that fails to join.
      cleanupWithin $ Http.withTransport configured {Config.endpoint = Text.pack ("http://127.0.0.1:" <> show port <> "/api/v0"), Config.responseTimeoutMillis = 250} $ \transport -> do
        outcome <- Http.send transport request
        assertBool "refused connection neither failed nor reached its request deadline" (outcome == Left Http.ConnectionFailure || outcome == Left Http.Timeout)
        Http.checkOpen transport >>= (@?= Right ())
        putMVar escaped transport
      transport <- within (takeMVar escaped)
      Http.checkOpen transport >>= (@?= Left Http.Closed)
    _ -> assertFailure "unexpected refused fixture socket family"

tlsEndpoint :: String -> String
tlsEndpoint endpoint = "https://localhost:" <> drop (length ("http://127.0.0.1:" :: String)) endpoint

fixtureRoots :: Certificates.CertificateStore
fixtureRoots = Certificates.makeCertificateStore (Certificates.readSignedObjectFromMemory fixtureCertificate)

withTlsServer :: (WireRequest -> IO ByteString) -> (String -> IO a) -> IO a
withTlsServer handler = withSocketServer (pure ()) (serveTls handler)

serveTls :: (WireRequest -> IO ByteString) -> Socket.Socket -> STM () -> IO ()
serveTls handler socket _ = withTlsContext socket $ \context -> do
  incoming <- receiveWith (Tls.recvData context)
  reply <- handler incoming
  Tls.sendData context (Lazy.fromStrict reply)

withTlsContext :: Socket.Socket -> (Tls.Context -> IO a) -> IO a
withTlsContext socket action = do
  credential <- require (Tls.credentialLoadX509FromMemory fixtureCertificate fixturePrivateKey)
  backend <- Connection.socketBackend socket
  let defaults = Tls.defaultParamsServer
      parameters =
        defaults
          { Tls.serverShared = (Tls.serverShared defaults) {Tls.sharedCredentials = Tls.Credentials [credential]},
            Tls.serverSupported = Tls.defaultSupported {Tls.supportedCiphers = Cipher.ciphersuite_default}
          }
  bracket (Tls.contextNew backend parameters) Tls.contextClose $ \context -> do
    Tls.handshake context
    action context

lifetime :: IO ()
lifetime = do
  traceFixture "lifetime entered test action"
  configured <- config
  started <- newEmptyMVar
  gate <- newEmptyMVar
  finished <- newEmptyMVar
  escaped <- newEmptyMVar
  workerResult <- newEmptyMVar
  let handler _ = putMVar started () >> takeMVar gate >> pure (response 200 "done" [])
  traceFixture "lifetime entering server acquisition"
  withServer handler $ \endpoint -> do
    traceFixture "lifetime starting owner and send"
    owner <-
      forkFinally
        ( Http.withTransport configured {Config.endpoint = Text.pack endpoint} $ \transport -> do
            putMVar escaped transport
            _ <- forkFinally (Http.send transport request) (putMVar workerResult)
            within (readMVar started)
            traceFixture "lifetime owner leaving transport callback"
        )
        (putMVar finished)
    ( do
        transport <- within (takeMVar escaped)
        traceFixture "lifetime waiting for handler entry"
        within (readMVar started)
        -- Scope exit has invalidated new work, but must wait for the old response.
        traceFixture "lifetime waiting for scope closure"
        within (waitClosed transport)
        traceFixture "lifetime scope closed; checking active send remains joined"
        tryTakeMVar finished >>= assertBool "scope joins in-flight send" . isNothing
        Http.send transport request >>= (@?= Left Http.Closed)
        traceFixture "lifetime releasing response gate"
        putMVar gate ()
        traceFixture "lifetime waiting for send result"
        outcome <- within (takeMVar workerResult)
        either (assertFailure . show) (\result -> fmap Http.status result @?= Right 200) outcome
        traceFixture "lifetime waiting for owner exit"
        within (readMVar finished) >>= either (assertFailure . show) pure
        closedAgain <- Http.checkOpen transport
        closedAgain @?= Left Http.Closed
        Http.send transport request >>= (@?= Left Http.Closed)
      )
      `finally` do
        traceFixture "lifetime finalizer releasing gate and joining owner cancellation"
        void (tryPutMVar gate ())
        cleanupWithin (killThread owner >> readMVar finished >> pure ())
    traceFixture "lifetime leaving server scope"

waitClosed :: Http.Transport -> IO ()
waitClosed transport = do
  state <- Http.checkOpen transport
  case state of
    Left Http.Closed -> pure ()
    Left failure -> assertFailure (show failure)
    Right () -> yield >> waitClosed transport

-- The stop signal must work both before accept starts and while it is blocked.
-- A real loopback connection wakes Windows' safe blocking accept; neither closing
-- a socket from another thread nor throwing an async exception establishes this.
fixtureCleanup :: IO ()
fixtureCleanup = forM_ [1 .. 20 :: Int] $ \iteration -> do
  called <- newIORef False
  withServer (\_ -> writeIORef called True >> pure B.empty) $ \_ ->
    when (even iteration) (threadDelay 1000)
  readIORef called >>= (@?= False)

fixtureConnections :: IO ()
fixtureConnections = Socket.withSocketsDo $ do
  entered <- newEmptyMVar
  received <- newEmptyMVar
  gate <- newEmptyMVar
  let handler _ = putMVar entered () >> takeMVar gate >> pure B.empty
  -- Keep the peer alive beyond fixture exit: cleanup must release a worker in
  -- recv itself, rather than depending on a well-behaved client sending EOF.
  traceFixture "incomplete client starting"
  bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \peer ->
    withServerReady (putMVar received ()) handler $ \endpoint -> do
      port <- endpointPort endpoint
      Socket.connect peer (Socket.SockAddrInet port (Socket.tupleToHostAddress (127, 0, 0, 1)))
      Socket.sendAll peer "GET /unfinished HTTP/1.1\r\n"
      within (takeMVar received)
  traceFixture "incomplete client cleanup joined; blocked handler starting"
  -- Wait for the handler itself, rather than racing HTTP request startup against
  -- a short client timeout. The peer remains open while fixture exit cancels a
  -- worker that has finished socket input and is blocked in Haskell code.
  bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \peer ->
    withServer handler $ \endpoint -> do
      port <- endpointPort endpoint
      Socket.connect peer (Socket.SockAddrInet port (Socket.tupleToHostAddress (127, 0, 0, 1)))
      Socket.sendAll peer "GET /blocked HTTP/1.1\r\nHost: fixture\r\n\r\n"
      within (takeMVar entered)
  traceFixture "blocked handler cleanup joined"

fixtureException :: IO ()
fixtureException = do
  outcome <- (withServer (\_ -> pure B.empty) (\_ -> ioError (userError "fixture continuation failed")) >> pure False) `catch` expected
  assertBool "continuation exception survives joined fixture cleanup" outcome
  where
    expected :: IOException -> IO Bool
    expected failure = pure ("fixture continuation failed" `Text.isInfixOf` Text.pack (show failure))

fixtureDeadline :: IO ()
fixtureDeadline = do
  gate <- newEmptyMVar
  finished <- newEmptyMVar
  ( do
      outcome <- within (try (cleanupWithinMicros 10000 (takeMVar gate `finally` putMVar finished ())) :: IO (Either SomeException ()))
      case outcome of
        Left failure -> assertBool "cleanup timeout is a visible failure" ("fixture cleanup timed out" `Text.isInfixOf` Text.pack (show failure))
        Right () -> assertFailure "cleanup timeout became success"
      tryTakeMVar finished >>= assertBool "unfinished cleanup retains ownership" . isNothing
    )
    `finally` (putMVar gate () >> within (takeMVar finished))

endpointPort :: String -> IO Socket.PortNumber
endpointPort endpoint = case reads (takeWhile (/= '/') (drop (length ("http://127.0.0.1:" :: String)) endpoint)) of
  [(port, "")] -> pure port
  _ -> assertFailure "invalid local fixture endpoint" >> fail "fixture endpoint"

-- A local HTTP fixture owns its listener, accept worker and every connection
-- worker. No public endpoint is contacted, and only a fixed fake project ID is used.
withServer :: (WireRequest -> IO ByteString) -> (String -> IO a) -> IO a
withServer = withServerReady (pure ())

withServerReady :: IO () -> (WireRequest -> IO ByteString) -> (String -> IO a) -> IO a
withServerReady connectionReady handler = withSocketServer connectionReady serve
  where
    serve connection cancelled = do
      incoming <- receive connection cancelled
      bytes <- handler incoming
      outcome <- Socket.sendAllWith connection bytes cancelled
      either (const (throwIO ThreadKilled)) pure outcome

withSocketServer :: IO () -> (Socket.Socket -> STM () -> IO ()) -> (String -> IO a) -> IO a
withSocketServer connectionReady serve action = Socket.withSocketsDo $ mask $ \restore -> do
  traceFixture "server acquiring listener"
  listener <- open
  traceFixture "server querying listener address"
  address <- Socket.getSocketName listener `onException` Socket.close listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure value
    _ -> Socket.close listener >> assertFailure "unexpected fixture socket family" >> fail "fixture"
  workers <- newMVar []
  stopping <- newTVarIO False
  accepted <- newEmptyMVar
  bracket
    (forkFinally (restore (acceptLoop listener workers stopping)) (putMVar accepted) `onException` Socket.close listener)
    (const (cleanupWithin (stop listener address workers stopping accepted)))
    ( \_ -> do
        traceFixture "server entering client action"
        restore (action ("http://127.0.0.1:" <> show port <> "/api/v0"))
    )
  where
    open = bracketOnError createSocket Socket.close $ \listener -> do
      traceFixture "server setting listener reuse option"
      Socket.setSocketOption listener Socket.ReuseAddr 1
      traceFixture "server binding listener"
      Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
      traceFixture "server listening"
      Socket.listen listener 8
      pure listener
    createSocket = do
      traceFixture "server creating socket"
      Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    acceptLoop listener workers stopping = mask $ \restore -> do
      (connection, _) <- Socket.accept listener
      shouldStop <- readTVarIO stopping
      if shouldStop
        then Socket.close connection
        else do
          finished <- newEmptyMVar
          let cancelled = check =<< readTVar stopping
          worker <-
            forkFinally
              (restore (connectionReady >> serve connection cancelled))
              (const (Socket.close connection `finally` putMVar finished ()))
              `onException` Socket.close connection
          modifyMVar_ workers (pure . ((worker, finished) :))
          restore (acceptLoop listener workers stopping)
    stop listener address workers stopping accepted = do
      atomically (writeTVar stopping True)
      -- Do not close the listener concurrently with accept. In network-3.2.12.0
      -- withFdSocket takes no lock, and Winsock does not promise that closesocket
      -- cancels a synchronous accept. Wake it normally, join, then close.
      ( do
          bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \wake ->
            Socket.connect wake address
          outcome <- readMVar accepted
          Socket.close listener
          either throwIO pure outcome
        )
        `finally` do
          connections <- readMVar workers
          forM_ connections $ \(worker, finished) -> killThread worker >> readMVar finished

-- timeout cannot interrupt a safe blocking foreign call, and killThread waits
-- synchronously for delivery. Give the cleanup worker ownership until it joins;
-- the test thread waits only on an interruptible MVar, so a failed shutdown is a
-- bounded test failure rather than a six-hour CI hang. Successful cleanup joins
-- every worker and closes every socket before returning.
cleanupWithin :: IO () -> IO ()
cleanupWithin = cleanupWithinMicros 2000000

cleanupWithinMicros :: Int -> IO () -> IO ()
cleanupWithinMicros deadline action = do
  finished <- newEmptyMVar
  _ <- forkFinally action (putMVar finished)
  outcome <- timeout deadline (takeMVar finished)
  case outcome of
    Nothing -> assertFailure "local HTTP fixture cleanup timed out"
    Just result -> either throwIO pure result

receive :: Socket.Socket -> STM () -> IO WireRequest
receive connection cancelled = receiveWith $ do
  outcome <- Socket.recvWith connection 4096 cancelled
  either (const (throwIO ThreadKilled)) pure outcome

receiveWith :: IO ByteString -> IO WireRequest
receiveWith receiveChunk = do
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
          chunk <- receiveChunk
          if B.null chunk || B.length accumulated > 65536 then fail "incomplete fixture headers" else headerBytes (accumulated <> chunk)
    remainingBytes size accumulated
      | B.length accumulated >= size = pure (B.take size accumulated)
      | otherwise = do
          chunk <- receiveChunk
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

-- Enabled only for CI diagnosis: each phase is flushed through stderr even when
-- a Windows foreign call or an uninterruptible owner prevents test completion.
traceFixture :: String -> IO ()
traceFixture phase = do
  enabled <- lookupEnv "COMETA_HTTP_FIXTURE_TRACE"
  when (enabled == Just "1") (hPutStrLn stderr ("HTTP fixture: " <> phase))

-- Newly authored localhost-only TLS fixture. These PUBLIC test credentials have
-- no wallet or production use. Certificate validity is 2020-2120 and SAN contains
-- localhost only, so a 127.0.0.1 endpoint must fail hostname verification.
fixtureCertificate :: ByteString
fixtureCertificate =
  C.unlines
    [ "-----BEGIN CERTIFICATE-----",
      "MIIBhjCCASygAwIBAgIBATAKBggqhkjOPQQDAjAUMRIwEAYDVQQDDAlsb2NhbGhv",
      "c3QwIBcNMjAwMTAxMDAwMDAwWhgPMjEyMDAxMDEwMDAwMDBaMBQxEjAQBgNVBAMM",
      "CWxvY2FsaG9zdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABIbSghSljv2c93Tj",
      "CkxU2qvUzPch2gZDuuPriZMMv1e6uoOCZqCE6+VC2TfDGegPQFZq6SsXtrUdJruP",
      "u17S3bejbTBrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgKEMBMGA1Ud",
      "JQQMMAoGCCsGAQUFBwMBMBQGA1UdEQQNMAuCCWxvY2FsaG9zdDAdBgNVHQ4EFgQU",
      "Atnqaqx2desr7wObh/tm/LyDWyAwCgYIKoZIzj0EAwIDSAAwRQIgRyVixABHThhu",
      "jzjA1TqXWdfnYZmhmm4AqNH8QVmBMy4CIQCCi1wVU6EeyQcxLIAEiov5w0yz8Jd3",
      "wgDMGpEmTZedZg==",
      "-----END CERTIFICATE-----"
    ]

fixturePrivateKey :: ByteString
fixturePrivateKey =
  C.unlines
    [ "-----BEGIN EC PRIVATE KEY-----",
      "MHcCAQEEIKxMaeDo1qhVDq1GdXY1GAOUsRd6Ngx3drYGjpxtPyFFoAoGCCqGSM49",
      "AwEHoUQDQgAEhtKCFKWO/Zz3dOMKTFTaq9TM9yHaBkO64+uJkwy/V7q6g4JmoITr",
      "5ULZN8MZ6A9AVmrpKxe2tR0mu4+7XtLdtw==",
      "-----END EC PRIVATE KEY-----"
    ]
