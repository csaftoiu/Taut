{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
module Common.Route where

import Prelude hiding (id, (.))

import Control.Category (Category (..))
import Control.Monad.Except
import Data.Functor.Identity
import Data.Functor.Sum
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar
import Data.Time.Clock
import GHC.Natural
import Text.Read (readMaybe)

import Obelisk.OAuth.Authorization
import Obelisk.Route
import Obelisk.Route.TH

import Common.Slack.Internal


newtype PaginatedRoute a = PaginatedRoute { unPaginatedRoute ::  (Natural, a) }
  deriving (Eq, Show, Ord)

mkPaginatedRouteAtPage1 :: a -> PaginatedRoute a
mkPaginatedRouteAtPage1 = PaginatedRoute . (1, )

paginatedRoutePageIndex :: PaginatedRoute a -> Natural
paginatedRoutePageIndex = fst . unPaginatedRoute

paginatedRouteValue :: PaginatedRoute a -> a
paginatedRouteValue = snd . unPaginatedRoute

data BackendRoute :: * -> * where
  -- | Used to handle unparseable routes.
  BackendRoute_Missing :: BackendRoute ()
  BackendRoute_OAuth :: BackendRoute (R OAuth)
  BackendRoute_GetSearchExamples :: BackendRoute ()
  BackendRoute_LocateMessage :: BackendRoute UTCTime
  BackendRoute_SearchMessages :: BackendRoute (PaginatedRoute Text)

data FrontendRoute :: * -> * where
  FrontendRoute_Home :: FrontendRoute ()
  FrontendRoute_Search :: FrontendRoute (PaginatedRoute Text)

backendRouteEncoder
  :: Encoder (Either Text) Identity (R (Sum BackendRoute (ObeliskRoute FrontendRoute))) PageName
backendRouteEncoder = handleEncoder (const (InL BackendRoute_Missing :/ ())) $
  pathComponentEncoder $ \case
    InL backendRoute -> case backendRoute of
      BackendRoute_Missing -> PathSegment "missing" $ unitEncoder mempty
      BackendRoute_OAuth -> PathSegment "oauth" oauthRouteEncoder
      BackendRoute_GetSearchExamples -> PathSegment "get-search-examples" $ unitEncoder mempty
      BackendRoute_LocateMessage -> PathSegment "locate-message" utcTimeEncoder
      BackendRoute_SearchMessages -> PathSegment "search-messages" $
        paginatedEncoder textEncoderImpl
    InR obeliskRoute -> obeliskRouteSegment obeliskRoute $ \case
      -- The encoder given to PathEnd determines how to parse query parameters,
      -- in this example, we have none, so we insist on it.
      FrontendRoute_Home -> PathEnd $ unitEncoder mempty
      FrontendRoute_Search -> PathSegment "search" $
        paginatedEncoder textEncoderImpl

utcTimeEncoder
  :: (Applicative check, MonadError Text parse)
  => Encoder check parse UTCTime PageName
utcTimeEncoder = unsafeMkEncoder $ EncoderImpl
  { _encoderImpl_decode = \([path], _query) -> do
      parseSlackTimestamp path
  , _encoderImpl_encode = \t -> ([formatSlackTimestamp t], mempty)
  }

paginatedEncoder
  :: (Applicative check, MonadError Text parse)
  => EncoderImpl parse a [Text]
  -> Encoder check parse (PaginatedRoute a) PageName
paginatedEncoder aEncoderImpl = unsafeMkEncoder $ EncoderImpl
    { _encoderImpl_decode = \(path, query) -> do
        a <- _encoderImpl_decode aEncoderImpl path
        pure $ PaginatedRoute
          ( fromMaybe 1 $ read . T.unpack <$> join (Map.lookup "page" query)
          , a
          )
    , _encoderImpl_encode = \(PaginatedRoute (n, a)) ->
        ( _encoderImpl_encode aEncoderImpl a
        , if n > 1 then Map.singleton "page" (Just $ T.pack $ show n) else mempty
        )
    }

-- TODO: shouldn't need this.
textEncoderImpl
  :: (MonadError Text parse)
  => EncoderImpl parse Text [Text]
textEncoderImpl = EncoderImpl
  { _encoderImpl_decode = \case
      [x] -> pure x
      _ -> throwError "textEncoderImpl: expected exactly 1 path element"
  , _encoderImpl_encode = \x -> [x]
  }

dayEncoder
  :: (Applicative check, MonadError Text parse)
  => Encoder check parse Day [Text]
dayEncoder = unsafeMkEncoder dayEncoderImpl

dayEncoderImpl
  :: (MonadError Text parse)
  => EncoderImpl parse Day [Text]
dayEncoderImpl = EncoderImpl
  { _encoderImpl_decode = \case
      [y, m, d] -> maybe (throwError "dayEncoder: invalid day") pure $ parseDay y m d
      _ -> throwError "dayEncoder: expected exactly 3 path elements"
  , _encoderImpl_encode = \day -> encodeDay day
  }
  where
    parseDay y' m' d' = do
      y <- readMaybe $ T.unpack y'
      m <- readMaybe $ T.unpack m'
      d <- readMaybe $ T.unpack d'
      fromGregorianValid y m d

encodeDay :: Day -> [Text]
encodeDay day = [T.pack $ show y, T.pack $ show m, T.pack $ show d]
  where
    (y, m, d) = toGregorian day


concat <$> mapM deriveRouteComponent
  [ ''FrontendRoute
  , ''BackendRoute
  ]
