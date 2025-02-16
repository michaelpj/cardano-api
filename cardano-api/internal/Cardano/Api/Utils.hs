{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

#if !defined(mingw32_HOST_OS)
#define UNIX
#endif

-- | Internal utils for the other Api modules
--
module Cardano.Api.Utils
  ( (?!)
  , (?!.)
  , formatParsecError
  , failEither
  , failEitherWith
  , noInlineMaybeToStrictMaybe
  , note
  , parseFilePath
  , readFileBlocking
  , runParsecParser
  , textShow
  , modifyWith

    -- ** CLI option parsing
  , bounded
  ) where

import           Cardano.Ledger.Shelley ()

import           Control.Exception (bracket)
import           Control.Monad (when)
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LBS
import           Data.Maybe.Strict
import           Data.Text (Text)
import qualified Data.Text as Text
import           GHC.IO.Handle.FD (openFileBlocking)
import           Options.Applicative (ReadM)
import qualified Options.Applicative as Opt
import           Options.Applicative.Builder (eitherReader)
import           System.IO (IOMode (ReadMode), hClose)
import qualified Text.Parsec as Parsec
import qualified Text.Parsec.String as Parsec
import qualified Text.ParserCombinators.Parsec.Error as Parsec
import qualified Text.Read as Read


(?!) :: Maybe a -> e -> Either e a
Nothing ?! e = Left e
Just x  ?! _ = Right x

(?!.) :: Either e a -> (e -> e') -> Either e' a
Left  e ?!. f = Left (f e)
Right x ?!. _ = Right x

{-# NOINLINE noInlineMaybeToStrictMaybe #-}
noInlineMaybeToStrictMaybe :: Maybe a -> StrictMaybe a
noInlineMaybeToStrictMaybe Nothing = SNothing
noInlineMaybeToStrictMaybe (Just x) = SJust x

formatParsecError :: Parsec.ParseError -> String
formatParsecError err =
  Parsec.showErrorMessages "or" "unknown parse error"
    "expecting" "unexpected" "end of input"
    $ Parsec.errorMessages err

runParsecParser :: Parsec.Parser a -> Text -> Aeson.Parser a
runParsecParser parser input =
  case Parsec.parse (parser <* Parsec.eof) "" (Text.unpack input) of
    Right txin -> pure txin
    Left parseError -> fail $ formatParsecError parseError

failEither :: MonadFail m => Either String a -> m a
failEither = either fail pure

failEitherWith :: MonadFail m => (e -> String) -> Either e a -> m a
failEitherWith f = either (fail . f) pure

note :: MonadFail m => String -> Maybe a -> m a
note msg = \case
  Nothing -> fail msg
  Just a -> pure a

parseFilePath :: String -> String -> Opt.Parser FilePath
parseFilePath optname desc =
  Opt.strOption
    ( Opt.long optname
    <> Opt.metavar "FILEPATH"
    <> Opt.help desc
    <> Opt.completer (Opt.bashCompleter "file")
    )

readFileBlocking :: FilePath -> IO BS.ByteString
readFileBlocking path = bracket
  (openFileBlocking path ReadMode)
  hClose
  (\fp -> do
    -- An arbitrary block size.
    let blockSize = 4096
    let go acc = do
          next <- BS.hGet fp blockSize
          if BS.null next
          then pure acc
          else go (acc <> Builder.byteString next)
    contents <- go mempty
    pure $ LBS.toStrict $ Builder.toLazyByteString contents)

textShow :: Show a => a -> Text
textShow = Text.pack . show

bounded :: forall a. (Bounded a, Integral a, Show a) => String -> ReadM a
bounded t = eitherReader $ \s -> do
  i <- Read.readEither @Integer s
  when (i < fromIntegral (minBound @a)) $ Left $ t <> " must not be less than " <> show (minBound @a)
  when (i > fromIntegral (maxBound @a)) $ Left $ t <> " must not greater than " <> show (maxBound @a)
  pure (fromIntegral i)

-- | Aids type inference.  Use this function to ensure the value is a function
-- that modifies a value.
modifyWith :: ()
  => (a -> a)
  -> (a -> a)
modifyWith = id

