{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ParallelListComp #-}

module Markdown (renderMessage, renderText, blockGetURLs, cursorSentinel) where

import           Brick ( (<+>), Widget, textWidth )
import qualified Brick.Widgets.Border as B
import qualified Brick.Widgets.Border.Style as B
import qualified Brick as B
import           Cheapskate.Types ( Block
                                  , Blocks
                                  , Inlines
                                  , ListType
                                  )
import qualified Cheapskate as C
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Foldable as F
import           Data.Monoid ((<>))
import           Data.Sequence ( Seq
                               , ViewL(..)
                               , ViewR(..)
                               , (<|)
                               , (|>)
                               , viewl
                               , viewr)
import qualified Data.Sequence as S
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Graphics.Vty as V
import           Lens.Micro.Platform ((^.))

import           Themes
import           Types

type UserSet = Set Text

omitUsernameTypes :: [MessageType]
omitUsernameTypes =
    [ CP Join
    , CP Leave
    , CP TopicChange
    ]

getReplyToMessage :: Message -> Maybe Message
getReplyToMessage m =
    case m^.mInReplyToMsg of
        ParentLoaded _ parent -> Just parent
        _ -> Nothing

renderMessage :: Message -> Bool -> UserSet -> Widget a
renderMessage msg renderReplyParent uSet =
    let msgUsr = case msg^.mUserName of
          Just u
            | msg^.mType `elem` omitUsernameTypes -> Nothing
            | otherwise -> Just u
          Nothing -> Nothing
        mine = case msgUsr of
          Just un
            | msg^.mType == CP Emote -> B.txt "*" <+> colorUsername un
                                    <+> B.txt " " <+> renderMarkdown uSet (msg^.mText)
            | otherwise -> colorUsername un <+> B.txt ": " <+> renderMarkdown uSet (msg^.mText)
          Nothing -> renderMarkdown uSet (msg^.mText)
        parent = if not renderReplyParent
                 then Nothing
                 else getReplyToMessage msg
    in case parent of
        Nothing -> mine
        Just m -> let parentMsg = renderMessage m False uSet
                  in (B.str " " <+> B.borderElem B.bsCornerTL <+> B.str "▸" <+>
                     (addEllipsis $ B.forceAttr replyParentAttr parentMsg))
                      B.<=> mine

addEllipsis :: Widget a -> Widget a
addEllipsis w = B.Widget (B.hSize w) (B.vSize w) $ do
    ctx <- B.getContext
    let aw = ctx^.B.availWidthL
    result <- B.render w
    let withEllipsis = (B.hLimit (aw - 3) $ B.vLimit 1 $ (B.Widget B.Fixed B.Fixed $ return result)) <+>
                       B.str "..."
    if (V.imageHeight (result^.B.imageL) > 1) || (V.imageWidth (result^.B.imageL) == aw) then
        B.render withEllipsis else
        return result

-- Cursor sentinel for tracking the user's cursor position in previews.
cursorSentinel :: Char
cursorSentinel = '‸'

-- Render markdown with username highlighting
renderMarkdown :: UserSet -> Blocks -> Widget a
renderMarkdown uSet bs = vBox (fmap (toWidget uSet) bs)

-- Render text to markdown without username highlighting
renderText :: Text -> Widget a
renderText txt = renderMarkdown Set.empty bs
  where C.Doc _ bs = C.markdown C.def txt

vBox :: F.Foldable f => f (Widget a) -> Widget a
vBox = B.vBox . F.toList

hBox :: F.Foldable f => f (Widget a) -> Widget a
hBox = B.hBox . F.toList

--

class ToWidget t where
  toWidget :: UserSet -> t -> Widget a

header :: Int -> Widget a
header n = B.txt (T.replicate n "#")

instance ToWidget Block where
  toWidget uPat (C.Para is) = toInlineChunk is uPat
  toWidget uPat (C.Header n is) =
    B.withDefAttr clientHeaderAttr
      (header n <+> B.txt " " <+> toInlineChunk is uPat)
  toWidget uPat (C.Blockquote is) =
    B.padLeft (B.Pad 4) (vBox $ fmap (toWidget uPat) is)
  toWidget uPat (C.List _ l bs) = toList l bs uPat
  toWidget _ (C.CodeBlock _ tx) =
    B.withDefAttr codeAttr $
      B.vBox [ B.txt " | " <+> textWithCursor ln | ln <- T.lines tx ]
  toWidget _ (C.HtmlBlock txt) = textWithCursor txt
  toWidget _ (C.HRule) = B.vLimit 1 (B.fill '*')

toInlineChunk :: Inlines -> UserSet -> Widget a
toInlineChunk is uSet = B.Widget B.Fixed B.Fixed $ do
  ctx <- B.getContext
  let width = ctx^.B.availWidthL
      fs    = toFragments is
      ws    = fmap gatherWidgets (split width uSet fs)
  B.render (vBox (fmap hBox ws))

toList :: ListType -> [Blocks] -> UserSet -> Widget a
toList lt bs uSet = vBox
  [ B.txt i <+> (vBox (fmap (toWidget uSet) b))
  | b <- bs | i <- is ]
  where is = case lt of
          C.Bullet _ -> repeat ("• ")
          C.Numbered _ _ -> [ T.pack (show (n :: Int)) <> ". "
                            | n <- [1..] ]

-- We want to do word-wrapping, but for that we want a linear
-- sequence of chunks we can break up. The typical Markdown
-- format doesn't fit the bill: when it comes to bold or italic
-- bits, we'd have treat it all as one. This representation is
-- more amenable to splitting up those bits.
data Fragment = Fragment
  { fTextual :: TextFragment
  , _fStyle  :: FragmentStyle
  } deriving (Show)

data TextFragment
  = TStr Text
  | TSpace
  | TSoftBreak
  | TLineBreak
  | TLink Text
  | TRawHtml Text
    deriving (Show, Eq)

data FragmentStyle
  = Normal
  | Emph
  | Strong
  | Code
  | User
  | Link
  | Emoji
    deriving (Eq, Show)

-- We convert it pretty mechanically:
toFragments :: Inlines -> Seq Fragment
toFragments = go Normal
  where go n c = case viewl c of
          C.Str t :< xs ->
            Fragment (TStr t) n <| go n xs
          C.Space :< xs ->
            Fragment TSpace n <| go n xs
          C.SoftBreak :< xs ->
            Fragment TSoftBreak n <| go n xs
          C.LineBreak :< xs ->
            Fragment TLineBreak n <| go n xs
          C.Link label url _ :< xs ->
            case F.toList label of
              [C.Str s] | s == url -> Fragment (TLink url) Link <| go n xs
              _                    -> go Link label <> go n xs
          C.RawHtml t :< xs ->
            Fragment (TRawHtml t) n <| go n xs
          C.Code t :< xs ->
            let ts  = [ Fragment frag Code
                      | wd <- T.split (== ' ') t
                      , frag <- case wd of
                          "" -> [TSpace]
                          _  -> [TSpace, TStr wd]
                      ]
                ts' = case ts of
                  (Fragment TSpace _:rs) -> rs
                  _                      -> ts
            in S.fromList ts' <> go n xs
          C.Emph is :< xs ->
            go Emph is <> go n xs
          C.Strong is :< xs ->
            go Strong is <> go n xs
          C.Image _ _ _ :< xs ->
            Fragment (TStr "[img]") Link <| go n xs
          C.Entity t :< xs ->
            Fragment (TStr t) Link <| go n xs
          EmptyL -> S.empty

--

data SplitState = SplitState
  { splitChunks  :: Seq (Seq Fragment)
  , splitCurrCol :: Int
  }

separate :: UserSet -> Seq Fragment -> Seq Fragment
separate uSet sq = case viewl sq of
  Fragment (TStr s) n :< xs -> gatherStrings s n xs
  Fragment x n :< xs        -> Fragment x n <| separate uSet xs
  EmptyL                    -> S.empty
  where gatherStrings s n rs =
          let s' = removeCursor s
          in case viewl rs of
            _ | s' `Set.member` uSet ||
                ("@" `T.isPrefixOf` s' && (T.drop 1 s' `Set.member` uSet)) ->
                buildString s n <| separate uSet rs
            Fragment (TStr s'') n' :< xs
              | n == n' -> gatherStrings (s <> s'') n xs
            Fragment _ _ :< _ -> buildString s n <| separate uSet rs
            EmptyL -> S.singleton (buildString s n)
        buildString s n =
            let s' = removeCursor s
            in if | ":" `T.isPrefixOf` s' &&
                    ":" `T.isSuffixOf` s' &&
                    textWidth s' > 2 ->
                      Fragment (TStr s) Emoji
                  | s' `Set.member` uSet ->
                      Fragment (TStr s) User
                  | "@" `T.isPrefixOf` (removeCursor s) &&
                    (T.drop 1 (removeCursor s) `Set.member` uSet) ->
                      Fragment (TStr s) User
                  | otherwise -> Fragment (TStr s) n

removeCursor :: T.Text -> T.Text
removeCursor = T.filter (/= cursorSentinel)

split :: Int -> UserSet -> Seq Fragment -> Seq (Seq Fragment)
split maxCols uSet = splitChunks
                   . go (SplitState (S.singleton S.empty) 0)
                   . separate uSet
  where go st (viewl-> f :< fs) = go st' fs
          where st' =
                  if | fTextual f == TSoftBreak || fTextual f == TLineBreak ->
                         st { splitChunks = splitChunks st |> S.empty
                            , splitCurrCol = 0
                            }
                     | available >= fsize ->
                         st { splitChunks  = addFragment f (splitChunks st)
                            , splitCurrCol = splitCurrCol st + fsize
                            }
                     | fTextual f == TSpace ->
                         st { splitChunks = splitChunks st |> S.empty
                            , splitCurrCol = 0
                            }
                     | otherwise ->
                         st { splitChunks  = splitChunks st |> S.singleton f
                            , splitCurrCol = fsize
                            }
                available = maxCols - splitCurrCol st
                fsize = fragmentSize f
                addFragment x (viewr-> ls :> l) = ( ls |> (l |> x))
                addFragment _ _ = error "[unreachable]"
        go st _                 = st

fragmentSize :: Fragment -> Int
fragmentSize f = case fTextual f of
  TStr t     -> textWidth t
  TLink t    -> textWidth t
  TRawHtml t -> textWidth t
  TSpace     -> 1
  TLineBreak -> 0
  TSoftBreak -> 0

strOf :: TextFragment -> Text
strOf f = case f of
  TStr t     -> t
  TLink t    -> t
  TRawHtml t -> t
  TSpace     -> " "
  _          -> ""

-- This finds adjacent string-ey fragments and concats them, so
-- we can use fewer widgets
gatherWidgets :: Seq Fragment -> Seq (Widget a)
gatherWidgets (viewl-> (Fragment frag style :< rs)) = go style (strOf frag) rs
  where go s t (viewl-> (Fragment f s' :< xs))
          | s == s' = go s (t <> strOf f) xs
        go s t xs =
          let w = case s of
                Normal -> textWithCursor t
                Emph   -> B.withDefAttr clientEmphAttr (textWithCursor t)
                Strong -> B.withDefAttr clientStrongAttr (textWithCursor t)
                Code   -> B.withDefAttr codeAttr (textWithCursor t)
                Link   -> B.withDefAttr urlAttr (textWithCursor t)
                Emoji  -> B.withDefAttr emojiAttr (textWithCursor t)
                User   -> B.withDefAttr (attrForUsername $ removeCursor t)
                                        (textWithCursor t)
          in w <| gatherWidgets xs
gatherWidgets _ =
  S.empty

textWithCursor :: T.Text -> Widget a
textWithCursor t
    | T.any (== cursorSentinel) t = B.visible $ B.txt $ removeCursor t
    | otherwise = B.txt t

inlinesToText :: Seq C.Inline -> T.Text
inlinesToText = F.fold . fmap go
  where go (C.Str t)       = t
        go C.Space         = " "
        go C.SoftBreak     = " "
        go C.LineBreak     = " "
        go (C.Emph is)     = F.fold (fmap go is)
        go (C.Strong is)   = F.fold (fmap go is)
        go (C.Code t)      = t
        go (C.Link is _ _) = F.fold (fmap go is)
        go (C.Image _ _ _) = "[img]"
        go (C.Entity t)    = t
        go (C.RawHtml t)   = t




blockGetURLs :: C.Block -> S.Seq (T.Text, T.Text)
blockGetURLs (C.Para is) = mconcat $ inlineGetURLs <$> F.toList is
blockGetURLs (C.Header _ is) = mconcat $ inlineGetURLs <$> F.toList is
blockGetURLs (C.Blockquote bs) = mconcat $ blockGetURLs <$> F.toList bs
blockGetURLs (C.List _ _ bss) = mconcat $ mconcat $ (blockGetURLs <$>) <$> (F.toList <$> bss)
blockGetURLs _ = mempty

inlineGetURLs :: C.Inline -> S.Seq (T.Text, T.Text)
inlineGetURLs (C.Emph is) = mconcat $ inlineGetURLs <$> F.toList is
inlineGetURLs (C.Strong is) = mconcat $ inlineGetURLs <$> F.toList is
inlineGetURLs (C.Link is url "") = (url, inlinesToText is) S.<| (mconcat $ inlineGetURLs <$> F.toList is)
inlineGetURLs (C.Link is _ url) = (url, inlinesToText is) S.<| (mconcat $ inlineGetURLs <$> F.toList is)
inlineGetURLs (C.Image is _ _) = mconcat $ inlineGetURLs <$> F.toList is
inlineGetURLs _ = mempty
