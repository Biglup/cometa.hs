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

-- | Private bounded HTTP transport. Credentials never enter diagnostics.
module Cometa.Provider.Blockfrost.Internal.Http
  ( Method (..),
    Request (..),
    Response (..),
    HttpFailure (..),
    Transport (..),
    withTransport,
    withEndpoint,
    maximumResponseBytes,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Provider.Blockfrost.Internal.Config as Config
import Control.Concurrent.MVar (MVar, modifyMVar, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Exception (bracket, finally, mask, try, uninterruptibleMask_)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import qualified Network.HTTP.Client as Http
import qualified Network.HTTP.Client.TLS as TLS
import qualified Network.HTTP.Types as HTTP
import qualified Network.HTTP.Types.URI as URI
import System.Timeout (timeout)

-- TYPES ----------------------------------------------------------------------

data Method = Get | Post deriving (Eq, Show)

-- No Show instance: request bodies may contain private transaction material.
data Request = Request
  { method :: !Method,
    path :: ![Text],
    query :: ![(Text, Text)],
    body :: !ByteString,
    contentType :: !ByteString,
    requestTimeoutMillis :: !(Maybe Int)
  }

data Response = Response
  { status :: !Int,
    bodyBytes :: !ByteString,
    retryAfter :: !(Maybe ByteString)
  }
  deriving (Eq, Show)

-- No raw exception/request/header/body text is retained.
data HttpFailure = Timeout | ConnectionFailure | ResponseTooLarge | Closed
  deriving (Eq, Show)

data Transport = Transport
  { send :: Request -> IO (Either HttpFailure Response),
    checkOpen :: IO (Either HttpFailure ())
  }

-- A closed scope drops its manager immediately; active calls hold their own
-- references until response cleanup. The last active caller signals drainage.
type Scope = MVar (Maybe Http.Manager, Int)

-- DEFINITIONS ----------------------------------------------------------------

maximumResponseBytes :: Int
maximumResponseBytes = 8 * 1024 * 1024

withTransport :: Config.Config -> (Transport -> IO a) -> IO a
withTransport config = withEndpoint config (Config.baseUrl (Config.network config))

-- | Private loopback-server fixture entrypoint; public callers choose a network,
-- never an arbitrary credential destination.
withEndpoint :: Config.Config -> String -> (Transport -> IO a) -> IO a
withEndpoint config endpoint action =
  either (const (ioError (userError "Invalid Blockfrost transport configuration"))) (const acquire) (Config.validateConfig config)
  where
    acquire = do
      template <- Http.parseRequest endpoint
      manager <- Http.newManager settings
      drained <- newEmptyMVar
      bracket (newMVar (Just manager, 0)) (closeScope drained) $ \scope ->
        action (Transport (sendScoped scope drained config template) (scopeOpen scope))
    -- http-client closeManager has been a deprecated no-op since 0.5. Managers
    -- reap automatically; disallow idle sockets so scope exit needs no GC to
    -- release connections. Disable the library's reused-connection retries too.
    settings =
      TLS.tlsManagerSettings
        { Http.managerRetryableException = const False,
          Http.managerIdleConnectionCount = 0
        }

-- | Check scope liveness without opening a connection or performing HTTP.
scopeOpen :: Scope -> IO (Either HttpFailure ())
scopeOpen scope = withMVar scope $ \(manager, _) -> pure (maybe (Left Closed) (const (Right ())) manager)

closeScope :: MVar () -> Scope -> IO ()
closeScope drained scope = uninterruptibleMask_ $ do
  active <- modifyMVar scope $ \(_, count) -> pure ((Nothing, count), count)
  when (active /= 0) (takeMVar drained)

sendScoped :: Scope -> MVar () -> Config.Config -> Http.Request -> Request -> IO (Either HttpFailure Response)
sendScoped scope drained config template request = mask $ \restore -> do
  acquired <- modifyMVar scope $ \(manager, count) ->
    pure ((manager, maybe count (const (count + 1)) manager), manager)
  case acquired of
    Nothing -> pure (Left Closed)
    Just manager ->
      restore (sendOnce config template manager request) `finally` release
  where
    release = modifyMVar scope $ \(manager, count) -> do
      when (count == 1 && isNothing manager) (putMVar drained ())
      pure ((manager, count - 1), ())

sendOnce :: Config.Config -> Http.Request -> Http.Manager -> Request -> IO (Either HttpFailure Response)
sendOnce config template manager request = do
  -- The outer deadline also covers connection acquisition, DNS and body reads;
  -- responseTimeout alone resets around individual network reads.
  result <- timeout (milliseconds * 1000) (tryHttp perform)
  pure $ case result of
    Nothing -> Left Timeout
    Just (Left failure) -> Left (classify failure)
    Just (Right response) -> response
  where
    milliseconds = max 1 (min (Config.responseTimeoutMillis config) (fromMaybe (Config.responseTimeoutMillis config) (requestTimeoutMillis request)))
    requestPath = B.dropWhileEnd (== 47) (Http.path template) <> B.concat ["/" <> URI.urlEncode False (Text.encodeUtf8 segment) | segment <- path request]
    headers =
      [("project_id", Config.projectIdBytes (Config.projectId config)), ("Accept", "application/json")]
        <> [("Content-Type", contentType request) | not (B.null (contentType request))]
    prepared =
      Http.setQueryString [(Text.encodeUtf8 key, Just (Text.encodeUtf8 value)) | (key, value) <- query request] $
        template
          { Http.method = case method request of Get -> "GET"; Post -> "POST",
            Http.path = requestPath,
            Http.requestHeaders = headers,
            Http.requestBody = Http.RequestBodyBS (body request),
            Http.redirectCount = 0,
            Http.checkResponse = \_ _ -> pure (),
            Http.responseTimeout = Http.responseTimeoutMicro (milliseconds * 1000),
            Http.cookieJar = Nothing
          }
    perform = Http.withResponse prepared manager $ \response -> do
      bytes <- readBounded maximumResponseBytes [] (Http.responseBody response)
      pure $ fmap (\payload -> Response (HTTP.statusCode (Http.responseStatus response)) payload (B.take 128 <$> lookup "Retry-After" (Http.responseHeaders response))) bytes

tryHttp :: IO a -> IO (Either Http.HttpException a)
tryHttp = try

classify :: Http.HttpException -> HttpFailure
classify failure = case failure of
  Http.HttpExceptionRequest _ Http.ResponseTimeout -> Timeout
  Http.HttpExceptionRequest _ Http.ConnectionTimeout -> Timeout
  _ -> ConnectionFailure

readBounded :: Int -> [ByteString] -> Http.BodyReader -> IO (Either HttpFailure ByteString)
readBounded remaining chunks reader = do
  chunk <- Http.brRead reader
  if B.null chunk
    then pure (Right (B.concat (reverse chunks)))
    else
      if B.length chunk > remaining
        then pure (Left ResponseTooLarge)
        else readBounded (remaining - B.length chunk) (chunk : chunks) reader
