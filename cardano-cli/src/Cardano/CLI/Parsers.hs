{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

{- HLINT ignore "Monoid law, left identity" -}

module Cardano.CLI.Parsers
  ( opts
  , pref
  , pConsensusModeParams
  , pNetworkId
  ) where

import           Cardano.CLI.Byron.Parsers (backwardsCompatibilityCommands, parseByronCommands)
import           Cardano.CLI.Common.Parsers (pConsensusModeParams, pNetworkId)
import           Cardano.CLI.Ping (parsePingCmd)
import           Cardano.CLI.Render (customRenderHelp)
import           Cardano.CLI.Run (ClientCommand (..))
import           Cardano.CLI.Shelley.Parsers (parseShelleyCommands)

import           Data.Foldable
import           Options.Applicative

import           Cardano.Api (NetworkId)
import qualified Options.Applicative as Opt

command' :: String -> String -> Parser a -> Mod CommandFields a
command' c descr p =
    command c $ info (p <**> helper)
              $ mconcat [ progDesc descr ]

opts :: Maybe NetworkId -> ParserInfo ClientCommand
opts mNetworkId =
  Opt.info (parseClientCommand mNetworkId <**> Opt.helper) $ mconcat
    [ Opt.fullDesc
    , Opt.header $ mconcat
      [ "cardano-cli - General purpose command-line utility to interact with cardano-node."
      , " Provides specific commands to manage keys, addresses, build & submit transactions,"
      , " certificates, etc."
      ]
    ]

pref :: ParserPrefs
pref = Opt.prefs $ mempty
  <> showHelpOnEmpty
  <> helpHangUsageOverflow 10
  <> helpRenderHelp customRenderHelp

parseClientCommand :: Maybe NetworkId -> Parser ClientCommand
parseClientCommand mNetworkId =
  asum
    -- There are name clashes between Shelley commands and the Byron backwards
    -- compat commands (e.g. "genesis"), and we need to prefer the Shelley ones
    -- so we list it first.
    [ parseShelley mNetworkId
    , parseByron mNetworkId
    , parsePing
    , parseDeprecatedShelleySubcommand mNetworkId
    , backwardsCompatibilityCommands mNetworkId
    , parseDisplayVersion (opts mNetworkId)
    ]

parseByron :: Maybe NetworkId -> Parser ClientCommand
parseByron mNetworkId =
  fmap ByronCommand $
  subparser $ mconcat
    [ commandGroup "Byron specific commands"
    , metavar "Byron specific commands"
    , command' "byron" "Byron specific commands" $ parseByronCommands mNetworkId
    ]

parsePing :: Parser ClientCommand
parsePing = CliPingCommand <$> parsePingCmd

-- | Parse Shelley-related commands at the top level of the CLI.
parseShelley :: Maybe NetworkId -> Parser ClientCommand
parseShelley mNetworkId = ShelleyCommand <$> parseShelleyCommands mNetworkId

-- | Parse Shelley-related commands under the now-deprecated \"shelley\"
-- subcommand.
--
-- Note that this subcommand is 'internal' and is therefore hidden from the
-- help text.
parseDeprecatedShelleySubcommand :: Maybe NetworkId -> Parser ClientCommand
parseDeprecatedShelleySubcommand mNetworkId =
  subparser $ mconcat
    [ commandGroup "Shelley specific commands (deprecated)"
    , metavar "Shelley specific commands"
    , command'
        "shelley"
        "Shelley specific commands (deprecated)"
        (DeprecatedShelleySubcommand <$> parseShelleyCommands mNetworkId)
    , internal
    ]

-- Yes! A --version flag or version command. Either guess is right!
parseDisplayVersion :: ParserInfo a -> Parser ClientCommand
parseDisplayVersion allParserInfo =
      subparser
        (mconcat
         [ commandGroup "Miscellaneous commands"
         , metavar "Miscellaneous commands"
         , command'
           "help"
           "Show all help"
           (pure (Help pref allParserInfo))
         , command'
           "version"
           "Show the cardano-cli version"
           (pure DisplayVersion)
         ]
        )
  <|> flag' DisplayVersion
        (  long "version"
        <> help "Show the cardano-cli version"
        <> hidden
        )
