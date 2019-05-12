{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
module Backend.Search.Parser where

import Control.Monad
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar
import Data.Time.Clock
import Data.Void
import Text.Read (readMaybe)
import GHC.Generics

import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import Common.Slack.Internal (parseSlackTimestamp)

data SearchModifier
  = SearchModifier_From Text  -- ^ Sent by person
  | SearchModifier_In Text  -- ^ In channel
  | SearchModifier_During Day
  | SearchModifier_At UTCTime  -- ^ At a specific message
  | SearchModifier_After Day
  | SearchModifier_Before Day
  | SearchModifier_HasPin
  -- | HasLink
  -- | HasEmoji EmojiCode
  deriving (Show, Generic)

newtype SearchKeyword = SearchKeyword { unSearchKeyword :: Text }
  deriving (Show, Generic)

type Parser = Parsec Void Text

searchModifier :: Parser SearchModifier
searchModifier =
      try (SearchModifier_From <$> (attribute "from" >> someWord))
  <|> try (SearchModifier_In <$> (attribute "in" >> someWord))
  <|>     (SearchModifier_During <$> (try (attribute "during") >> dayParser))
  <|>     (SearchModifier_At <$> (try (attribute "at") >> timeParser))
  <|>     (SearchModifier_After <$> (try (attribute "after") >> dayParser))
  <|>     (SearchModifier_Before <$> (try (attribute "before") >> dayParser))
  <|> try (SearchModifier_HasPin <$ string "has:pin")

dayParser :: Parser Day
dayParser = do
  let parseNum :: Read a => String -> Parser a
      parseNum e = maybe (fail e :: Parser a) pure =<< fmap readMaybe (some digitChar)
  year :: Integer <- parseNum "Expected year"
  _ <- string "-"
  month :: Int <- parseNum "Expected month"
  _ <- string "-"
  d :: Int <- parseNum "Expected day"
  maybe (fail "Invalid day") pure $ fromGregorianValid year month d

timeParser :: Parser UTCTime
timeParser = do
  ts :: Integer <- L.decimal
  parseSlackTimestamp $ T.pack (show ts)

searchKeyword :: Parser SearchKeyword
searchKeyword =
      (SearchKeyword <$> quotedText)
  <|> (SearchKeyword <$> someWord)

quotedText :: Parser Text
quotedText = do
  void $ try (string "\"")
  s <- T.pack <$> some (satisfy (/= '"'))
  void $ string "\""
  pure s

-- FIXME: Won't include stuff like hyphens.
someWord :: Parser Text
someWord = T.pack <$> some alphaNumChar -- TODO: Review the accuracy of this

attribute :: Text -> Parser ()
attribute name = void $ string $ name <> ":"

parseSearchQuery :: Text -> Either (ParseError Char Void) [Either SearchModifier SearchKeyword]
parseSearchQuery q = runParser p "<user-query>" q
  where
    p = sepBy (Left <$> searchModifier <|> Right <$> searchKeyword) space1
