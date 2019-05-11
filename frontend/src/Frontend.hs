{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
module Frontend where

import Control.Monad
import Data.Dependent.Sum (DSum ((:=>)))
import Data.Functor.Identity (Identity (..))
import Data.Semigroup ((<>))
import qualified Data.Text as T
import Data.Time.Calendar

import Reflex.Dom.Core

import Obelisk.Frontend
import Obelisk.Generated.Static
import Obelisk.Route.Frontend

import Common.Route
import Common.Slack.Types.Auth
import qualified Common.Slack.Types.Search as Search

import Frontend.Message
import Frontend.Util


frontend :: Frontend (R FrontendRoute)
frontend = Frontend
  { _frontend_head = do
      elAttr "base" ("href" =: "/") blank
      elAttr "meta" ("name" =: "viewport" <> "content" =: "width=device-width, initial-scale=1") blank
      el "title" $ text "Taut - Slack Archive Viewer"
      -- FIXME: This throws JSException
      -- el "title" $ subRoute_ $ \case
      --   Route_Home -> text "Taut"
      --   Route_Messages -> do
      --     r :: Dynamic t Day <- askRoute
      --     text "Taut - "
      --     dynText $ fmap (T.pack . show) r
      elAttr "link" ("rel" =: "stylesheet" <> "type" =: "text/css" <> "href" =: static @"semantic.min.css") blank
  , _frontend_body = do
      divClass "ui container" $ do
        divClass ("ui top attached inverted segment " <> themeColor) $
            routeLink (FrontendRoute_Home :/ ()) $
              elClass "h1" "ui inverted header" $ text "Taut - Slack Archive Viewer"
        userE <- divClass "ui attached segment" $ do
          divClass ("ui raised large segment " <> themeColor) $ divClass "ui search" $ do
            divClass "ui icon inverted fluid input" $ do
              r <- askRoute
              -- NOTE: setRoute should ideally scroll to top automaticlly, but it
              -- does not so we do it here.
              widgetHold_ blank $ ffor (updated r) $ const scrollToTop
              let query = ffor r $ \case
                    FrontendRoute_Home :=> Identity () -> ""
                    FrontendRoute_Search :=> Identity pr -> paginatedRouteValue pr
              searchInputWidgetWithRoute query $ \q ->
                FrontendRoute_Search :/ (PaginatedRoute (1, T.strip q))

          fmap switchDyn $ subRoute $ \case
            FrontendRoute_Home -> do
              resp <- getSearchExamples
              widgetHold_ blank $ ffor resp $ \case
                Nothing -> text "Unable to load search examples"
                Just (Left na) -> notAuthorizedWidget na
                Just (Right (_, examples)) -> do
                  elHeader "h2" (text "Search examples") $
                    text "Begin browsing the archive using these search queries!"
                  divClass "ui two column centered grid" $ divClass "column" $
                    divClass "ui list" $ forM_ examples $ \(title, query) -> do
                      divClass "item" $ divClass "ui piled segment" $ do
                        let r = FrontendRoute_Search :/ mkPaginatedRouteAtPage1 query
                        routeLinkClass r "ui header" $ text query
                        divClass "description" $ text title
                  el "p" blank
              pure $ fmap fst $ filterRight $ fforMaybe resp id
            FrontendRoute_Search -> do
              r  <- askRoute
              resp <- getMessages r (BackendRoute_SearchMessages :/)
              widgetHold_ (divClass "ui loading segment" blank) $ ffor resp $ \case
                Nothing -> text "Something went wrong"
                Just (Left na) -> notAuthorizedWidget na
                Just (Right (_, Left ())) -> do
                  divClass "ui error message" $ do
                    divClass "header" $ text "Bad search query"
                    el "p" $ text "Your search query is malformed."
                Just (Right (_, Right (mf, v))) -> do
                  case Search.isOnlyDuring mf of
                    Nothing -> do
                      elHeader "h2" (text "Results") $ do
                        text "Displaying messages matching the query "
                        el "tt" $ dynText $ paginatedRouteValue <$> r
                        text "."
                    Just day -> do
                      elHeader "h2" (text $ showDay day) $ do
                        text "Displaying messages sent on this day. "
                        text "Go to "
                        routeLink (routeForDay $ addDays (-1) day) $ do
                          el "b" $ text "previous"
                        text " day. Go to "
                        routeLink (routeForDay $ addDays 1 day) $
                          el "b" $ text "next"
                        text " day."
                  divClass "ui horizontal divider" blank
                  renderMessagesWithPagination r FrontendRoute_Search v
              pure $ fmap fst $ filterRight $ fforMaybe resp id
        divClass "ui bottom attached secondary segment" $ do
          elAttr "a" ("href" =: "https://github.com/srid/Taut") $ text "Powered by Haskell"
          widgetHold_ blank $ ffor userE $ \(SlackUser name _) ->
            divClass "item" $ text $ "Welcome " <> name
  }
  where
    notAuthorizedWidget :: DomBuilder t m => NotAuthorized -> m ()
    notAuthorizedWidget = \case
      NotAuthorized_RequireLogin grantHref -> divClass "ui segment" $ do
        el "p" $ text "You must login to Slack to access this page."
        slackLoginButton grantHref
      NotAuthorized_WrongTeam (SlackTeam teamId) grantHref -> divClass "ui segment" $ do
        el "p" $ text $ "Your team " <> teamId <> " does not match that of the archives. Please login to the correct team."
        slackLoginButton grantHref
      where
        slackLoginButton r = elAttr "a" ("href" =: r) $
          elAttr "img" ("src" =: "https://api.slack.com/img/sign_in_with_slack.png") blank

    renderMessagesWithPagination r mkR pm = do
      let pageW = dyn_ $ ffor r $ \pr ->
            paginationNav pm $ \p' -> mkR :/ (PaginatedRoute (p', paginatedRouteValue pr))
      pageW >> messageList pm >> pageW
