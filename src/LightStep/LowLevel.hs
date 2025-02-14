{-# LANGUAGE OverloadedStrings #-}

module LightStep.LowLevel
  ( module LightStep.LowLevel,
    Span,
  )
where

import Chronos
import Control.Lens hiding (op)
import Data.ProtoLens.Message (defMessage)
import qualified Data.Text as T
import LightStep.Internal.Debug
import Network.GRPC.Client
import Network.GRPC.Client.Helpers
import Network.HTTP2.Client
import Proto.Collector
import Proto.Collector_Fields
import Proto.Google.Protobuf.Timestamp_Fields

data LightStepClient = LightStepClient GrpcClient T.Text Reporter

data LightStepConfig
  = LightStepConfig
      { lsHostName :: HostName,
        lsPort :: PortNumber,
        lsToken :: T.Text,
        lsServiceName :: T.Text,
        lsGracefulShutdownTimeoutSeconds :: Int
      }

reportSpans :: LightStepClient -> [Span] -> ExceptT ClientError IO ()
reportSpans (LightStepClient grpc token rep) sps = do
  ret <-
    rawUnary
      (RPC :: RPC CollectorService "report")
      grpc
      ( defMessage
          & auth .~ (defMessage & accessToken .~ token)
          & spans .~ sps
          & reporter .~ rep
      )
  d_ (show ret)
  -- FIXME: handle errors
  pure ()

mkClient :: LightStepConfig -> ClientIO LightStepClient
mkClient LightStepConfig {..} = do
  grpc <- setupGrpcClient ((grpcClientConfigSimple lsHostName lsPort True) {_grpcClientConfigCompression = compression})
  pure $ LightStepClient grpc lsToken rep
  where
    compression = if False then gzip else uncompressed
    rep =
      defMessage
        & reporterId .~ 2
        & tags
          .~ [ defMessage & key .~ "span.kind" & stringValue .~ "server",
               defMessage & key .~ "lightstep.component_name" & stringValue .~ lsServiceName,
               defMessage & key .~ "lightstep.tracer_platform" & stringValue .~ "haskell"
             ]

closeClient :: LightStepClient -> ClientIO ()
closeClient (LightStepClient grpc _ _) = close grpc

startSpan :: T.Text -> IO Span
startSpan op = do
  nanosSinceEpoch <- getTime <$> now
  let sid = fromIntegral nanosSinceEpoch
      tid = fromIntegral nanosSinceEpoch
  pure $
    defMessage
      & operationName .~ op
      & startTimestamp
        .~ ( defMessage
               & seconds .~ (nanosSinceEpoch `div` 1_000_000_000)
               & nanos .~ fromIntegral (rem nanosSinceEpoch 1_000_000_000)
           )
      & spanContext
        .~ (defMessage & traceId .~ tid & spanId .~ sid)

finishSpan :: Span -> IO Span
finishSpan sp = do
  nanosSinceEpoch <- getTime <$> now
  let dur =
        (nanosSinceEpoch - (sp ^. startTimestamp . seconds) * 1_000_000_000 - fromIntegral (sp ^. startTimestamp . nanos))
          & (`div` 1000)
          & fromIntegral
  pure $
    sp
      & durationMicros .~ dur
