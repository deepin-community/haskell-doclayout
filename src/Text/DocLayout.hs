{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP               #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveDataTypeable #-}
{- |
   Module      : Text.DocLayout
   Copyright   : Copyright (C) 2010-2019 John MacFarlane
   License     : BSD 3

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

A prettyprinting library for the production of text documents,
including wrapped text, indentation and other prefixes, and
blocks for tables.
-}

module Text.DocLayout (
     -- * Rendering
       render
     -- * Doc constructors
     , cr
     , blankline
     , blanklines
     , space
     , literal
     , text
     , char
     , prefixed
     , flush
     , nest
     , hang
     , beforeNonBlank
     , nowrap
     , afterBreak
     , lblock
     , cblock
     , rblock
     , vfill
     , nestle
     , chomp
     , inside
     , braces
     , brackets
     , parens
     , quotes
     , doubleQuotes
     , empty
     -- * Functions for concatenating documents
     , (<+>)
     , ($$)
     , ($+$)
     , hcat
     , hsep
     , vcat
     , vsep
     -- * Functions for querying documents
     , isEmpty
     , offset
     , minOffset
     , updateColumn
     , height
     , charWidth
     , realLength
     , realLengthNoShortcut
     , isEmojiModifier
     , isEmojiVariation
     , isEmojiJoiner
     -- * Types
     , Doc(..)
     , HasChars(..)
     )

where
import Prelude
import Data.Maybe (fromMaybe)
import Data.Monoid (Sum(..))
import Safe (lastMay, initSafe)
import Control.Monad
import Control.Monad.State.Strict
import GHC.Generics
import Data.Char (isDigit, isSpace, ord)
import Data.List (foldl', intersperse)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.IntMap.Strict as IM
import Data.Data (Data, Typeable)
import Data.String
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Text (Text)
#if MIN_VERSION_base(4,11,0)
#else
import Data.Semigroup
#endif
import Text.Emoji (baseEmojis)

-- | Class abstracting over various string types that
-- can fold over characters.  Minimal definition is 'foldrChar'
-- and 'foldlChar', but defining the other methods can give better
-- performance.
class (IsString a, Semigroup a, Monoid a, Show a) => HasChars a where
  foldrChar     :: (Char -> b -> b) -> b -> a -> b
  foldlChar     :: (b -> Char -> b) -> b -> a -> b
  replicateChar :: Int -> Char -> a
  replicateChar n c = fromString (replicate n c)
  isNull        :: a -> Bool
  isNull = foldrChar (\_ _ -> False) True
  splitLines    :: a -> [a]
  splitLines s = (fromString firstline : otherlines)
   where
    (firstline, otherlines) = foldrChar go ([],[]) s
    go '\n' (cur,lns) = ([], fromString cur : lns)
    go c    (cur,lns) = (c:cur, lns)

instance HasChars Text where
  foldrChar         = T.foldr
  foldlChar         = T.foldl'
  splitLines        = T.splitOn "\n"
  replicateChar n c = T.replicate n (T.singleton c)
  isNull            = T.null

instance HasChars String where
  foldrChar     = foldr
  foldlChar     = foldl'
  splitLines    = lines . (++"\n")
  replicateChar = replicate
  isNull        = null

instance HasChars TL.Text where
  foldrChar         = TL.foldr
  foldlChar         = TL.foldl'
  splitLines        = TL.splitOn "\n"
  replicateChar n c = TL.replicate (fromIntegral n) (TL.singleton c)
  isNull            = TL.null

-- | Document, including structure relevant for layout.
data Doc a = Text Int a            -- ^ Text with specified width.
         | Block Int [a]           -- ^ A block with a width and lines.
         | VFill Int a             -- ^ A vertically expandable block;
                 -- when concatenated with a block, expands to height
                 -- of block, with each line containing the specified text.
         | Prefixed Text (Doc a)   -- ^ Doc with each line prefixed with text.
                 -- Note that trailing blanks are omitted from the prefix
                 -- when the line after it is empty.
         | BeforeNonBlank (Doc a)  -- ^ Doc that renders only before nonblank.
         | Flush (Doc a)           -- ^ Doc laid out flush to left margin.
         | BreakingSpace           -- ^ A space or line break, in context.
         | AfterBreak Text         -- ^ Text printed only at start of line.
         | CarriageReturn          -- ^ Newline unless we're at start of line.
         | NewLine                 -- ^ newline.
         | BlankLines Int          -- ^ Ensure a number of blank lines.
         | Concat (Doc a) (Doc a)  -- ^ Two documents concatenated.
         | Empty
         deriving (Show, Read, Eq, Ord, Functor, Foldable, Traversable,
                  Data, Typeable, Generic)

instance Semigroup (Doc a) where
  x <> Empty = x
  Empty <> x = x
  x <> y     = Concat x y

instance Monoid (Doc a) where
  mappend = (<>)
  mempty = Empty

instance HasChars a => IsString (Doc a) where
  fromString = text

-- | Unfold a 'Doc' into a flat list.
unfoldD :: Doc a -> [Doc a]
unfoldD Empty = []
unfoldD (Concat x@Concat{} y) = unfoldD x <> unfoldD y
unfoldD (Concat x y)          = x : unfoldD y
unfoldD x                     = [x]

-- | True if the document is empty.
isEmpty :: Doc a -> Bool
isEmpty Empty = True
isEmpty _     = False

-- | The empty document.
empty :: Doc a
empty = mempty

-- | Concatenate documents horizontally.
hcat :: [Doc a] -> Doc a
hcat = mconcat

-- | Concatenate a list of 'Doc's, putting breakable spaces
-- between them.
infixr 6 <+>
(<+>) :: Doc a -> Doc a -> Doc a
(<+>) x y
  | isEmpty x = y
  | isEmpty y = x
  | otherwise = x <> space <> y

-- | Same as 'hcat', but putting breakable spaces between the
-- 'Doc's.
hsep :: [Doc a] -> Doc a
hsep = foldr (<+>) empty

infixr 5 $$
-- | @a $$ b@ puts @a@ above @b@.
($$) :: Doc a -> Doc a -> Doc a
($$) x y
  | isEmpty x = y
  | isEmpty y = x
  | otherwise = x <> cr <> y

infixr 5 $+$
-- | @a $+$ b@ puts @a@ above @b@, with a blank line between.
($+$) :: Doc a -> Doc a -> Doc a
($+$) x y
  | isEmpty x = y
  | isEmpty y = x
  | otherwise = x <> blankline <> y

-- | List version of '$$'.
vcat :: [Doc a] -> Doc a
vcat = foldr ($$) empty

-- | List version of '$+$'.
vsep :: [Doc a] -> Doc a
vsep = foldr ($+$) empty

-- | Removes leading blank lines from a 'Doc'.
nestle :: Doc a -> Doc a
nestle d =
  case d of
    BlankLines _              -> Empty
    NewLine                   -> Empty
    Concat (Concat x y) z     -> nestle (Concat x (Concat y z))
    Concat BlankLines{} x     -> nestle x
    Concat NewLine x          -> nestle x
    _                         -> d

-- | Chomps trailing blank space off of a 'Doc'.
chomp :: Doc a -> Doc a
chomp d =
    case d of
    BlankLines _              -> Empty
    NewLine                   -> Empty
    CarriageReturn            -> Empty
    BreakingSpace             -> Empty
    Prefixed s d'             -> Prefixed s (chomp d')
    Concat (Concat x y) z     -> chomp (Concat x (Concat y z))
    Concat x y                ->
        case chomp y of
          Empty -> chomp x
          z     -> x <> z
    _                         -> d

type DocState a = State (RenderState a) ()

data RenderState a = RenderState{
         output     :: [a]        -- ^ In reverse order
       , prefix     :: Text
       , usePrefix  :: Bool
       , lineLength :: Maybe Int  -- ^ 'Nothing' means no wrapping
       , column     :: Int
       , newlines   :: Int        -- ^ Number of preceding newlines
       }

newline :: HasChars a => DocState a
newline = do
  st' <- get
  let rawpref = prefix st'
  when (column st' == 0 && usePrefix st' && not (T.null rawpref)) $ do
     let pref = fromString $ T.unpack $ T.dropWhileEnd isSpace rawpref
     modify $ \st -> st{ output = pref : output st
                       , column = column st + realLength pref }
  modify $ \st -> st { output = "\n" : output st
                     , column = 0
                     , newlines = newlines st + 1
                     }

outp :: HasChars a => Int -> a -> DocState a
outp off s = do           -- offset >= 0 (0 might be combining char)
  st' <- get
  let pref = fromString $ T.unpack $ prefix st'
  when (column st' == 0 && usePrefix st' && not (isNull pref)) $
    modify $ \st -> st{ output = pref : output st
                    , column = column st + realLength pref }
  modify $ \st -> st{ output = s : output st
                    , column = column st + off
                    , newlines = 0 }

-- | Render a 'Doc'.  @render (Just n)@ will use
-- a line length of @n@ to reflow text on breakable spaces.
-- @render Nothing@ will not reflow text.
render :: HasChars a => Maybe Int -> Doc a -> a
render linelen doc = mconcat . reverse . output $
  execState (renderDoc doc) startingState
   where startingState = RenderState{
                            output = mempty
                          , prefix = mempty
                          , usePrefix = True
                          , lineLength = linelen
                          , column = 0
                          , newlines = 2 }

renderDoc :: HasChars a => Doc a -> DocState a
renderDoc = renderList . normalize . unfoldD


normalize :: HasChars a => [Doc a] -> [Doc a]
normalize [] = []
normalize (Concat{} : xs) = normalize xs -- should not happen after unfoldD
normalize (Empty : xs) = normalize xs -- should not happen after unfoldD
normalize [NewLine] = normalize [CarriageReturn]
normalize [BlankLines _] = normalize [CarriageReturn]
normalize [BreakingSpace] = []
normalize (BlankLines m : BlankLines n : xs) =
  normalize (BlankLines (max m n) : xs)
normalize (BlankLines num : BreakingSpace : xs) =
  normalize (BlankLines num : xs)
normalize (BlankLines m : CarriageReturn : xs) = normalize (BlankLines m : xs)
normalize (BlankLines m : NewLine : xs) = normalize (BlankLines m : xs)
normalize (NewLine : BlankLines m : xs) = normalize (BlankLines m : xs)
normalize (NewLine : BreakingSpace : xs) = normalize (NewLine : xs)
normalize (NewLine : CarriageReturn : xs) = normalize (NewLine : xs)
normalize (CarriageReturn : CarriageReturn : xs) =
  normalize (CarriageReturn : xs)
normalize (CarriageReturn : NewLine : xs) = normalize (NewLine : xs)
normalize (CarriageReturn : BlankLines m : xs) = normalize (BlankLines m : xs)
normalize (CarriageReturn : BreakingSpace : xs) =
  normalize (CarriageReturn : xs)
normalize (BreakingSpace : CarriageReturn : xs) =
  normalize (CarriageReturn:xs)
normalize (BreakingSpace : NewLine : xs) = normalize (NewLine:xs)
normalize (BreakingSpace : BlankLines n : xs) = normalize (BlankLines n:xs)
normalize (BreakingSpace : BreakingSpace : xs) = normalize (BreakingSpace:xs)
normalize (x:xs) = x : normalize xs

mergeBlocks :: HasChars a => Int -> (Int, [a]) -> (Int, [a]) -> (Int, [a])
mergeBlocks h (w1,lns1) (w2,lns2) =
  (w, zipWith (\l1 l2 -> pad w1 l1 <> l2) lns1' lns2')
 where
  w  = w1 + w2
  len1 = length $ take h lns1  -- note lns1 might be infinite
  len2 = length $ take h lns2
  lns1' = if len1 < h
             then lns1 ++ replicate (h - len1) mempty
             else take h lns1
  lns2' = if len2 < h
             then lns2 ++ replicate (h - len2) mempty
             else take h lns2
  pad n s = s <> replicateChar (n - realLength s) ' '

renderList :: HasChars a => [Doc a] -> DocState a
renderList [] = return ()

renderList (Text off s : xs) = do
  outp off s
  renderList xs

renderList (Prefixed pref d : xs) = do
  st <- get
  let oldPref = prefix st
  put st{ prefix = prefix st <> pref }
  renderDoc d
  modify $ \s -> s{ prefix = oldPref }
  -- renderDoc CarriageReturn
  renderList xs

renderList (Flush d : xs) = do
  st <- get
  let oldUsePrefix = usePrefix st
  put st{ usePrefix = False }
  renderDoc d
  modify $ \s -> s{ usePrefix = oldUsePrefix }
  renderList xs

renderList (BeforeNonBlank d : xs) =
  case xs of
    (x:_) | startsBlank x -> renderList xs
          | otherwise     -> renderDoc d >> renderList xs
    []                    -> renderList xs
renderList (BlankLines num : xs) = do
  st <- get
  case output st of
     _ | newlines st > num -> return ()
       | otherwise -> replicateM_ (1 + num - newlines st) newline
  renderList xs

renderList (CarriageReturn : xs) = do
  st <- get
  if newlines st > 0
     then renderList xs
     else do
       newline
       renderList xs

renderList (NewLine : xs) = do
  newline
  renderList xs

renderList (BreakingSpace : xs) = do
  let isBreakingSpace BreakingSpace = True
      isBreakingSpace _ = False
  let xs' = dropWhile isBreakingSpace xs
  let next = takeWhile (not . isBreakable) xs'
  st <- get
  let off = foldl' (\tot t -> tot + offsetOf t) 0 next
  case lineLength st of
        Just l | column st + 1 + off > l -> newline
        _  -> when (column st > 0) $ outp 1 " "
  renderList xs'

renderList (AfterBreak t : xs) = do
  st <- get
  if newlines st > 0
     then renderList (fromString (T.unpack t) : xs)
     else renderList xs

renderList (b : xs) | isBlock b = do
  let (bs, rest) = span isBlock xs
  -- ensure we have right padding unless end of line
  let heightOf (Block _ ls) = length ls
      heightOf _            = 1
  let maxheight = maximum $ map heightOf (b:bs)
  let toBlockSpec (Block w ls) = (w, ls)
      toBlockSpec (VFill w t)  = (w, take maxheight $ repeat t)
      toBlockSpec _            = (0, [])
  let (_, lns') = foldl (mergeBlocks maxheight) (toBlockSpec b)
                             (map toBlockSpec bs)
  st <- get
  let oldPref = prefix st
  case column st - realLength oldPref of
        n | n > 0 -> modify $ \s -> s{ prefix = oldPref <> T.replicate n " " }
        _ -> return ()
  renderList $ intersperse CarriageReturn (map literal lns')
  modify $ \s -> s{ prefix = oldPref }
  renderList rest

renderList (x:_) = error $ "renderList encountered " ++ show x

isBreakable :: HasChars a => Doc a -> Bool
isBreakable BreakingSpace      = True
isBreakable CarriageReturn     = True
isBreakable NewLine            = True
isBreakable (BlankLines _)     = True
isBreakable (Concat Empty y)   = isBreakable y
isBreakable (Concat x _)       = isBreakable x
isBreakable _                  = False

startsBlank' :: HasChars a => a -> Bool
startsBlank' t = fromMaybe False $ foldlChar go Nothing t
  where
   go Nothing  c = Just (isSpace c)
   go (Just b) _ = Just b

startsBlank :: HasChars a => Doc a -> Bool
startsBlank (Text _ t)         = startsBlank' t
startsBlank (Block n ls)       = n > 0 && all startsBlank' ls
startsBlank (VFill n t)        = n > 0 && startsBlank' t
startsBlank (BeforeNonBlank x) = startsBlank x
startsBlank (Prefixed _ x)     = startsBlank x
startsBlank (Flush x)          = startsBlank x
startsBlank BreakingSpace      = True
startsBlank (AfterBreak t)     = startsBlank (Text 0 t)
startsBlank CarriageReturn     = True
startsBlank NewLine            = True
startsBlank (BlankLines _)     = True
startsBlank (Concat Empty y)   = startsBlank y
startsBlank (Concat x _)       = startsBlank x
startsBlank Empty              = True

isBlock :: Doc a -> Bool
isBlock Block{} = True
isBlock VFill{} = True
isBlock _       = False

offsetOf :: Doc a -> Int
offsetOf (Text o _)      = o
offsetOf (Block w _)     = w
offsetOf (VFill w _)     = w
offsetOf BreakingSpace   = 1
offsetOf _               = 0

-- | Create a 'Doc' from a stringlike value.
literal :: HasChars a => a -> Doc a
literal x =
  mconcat $
    intersperse NewLine $
      map (\s -> if isNull s
                    then Empty
                    else Text (realLength s) s) $
        splitLines x
{-# NOINLINE literal #-}

-- | A literal string.  (Like 'literal', but restricted to String.)
text :: HasChars a => String -> Doc a
text = literal . fromString

-- | A character.
char :: HasChars a => Char -> Doc a
char c = text $ fromString [c]

-- | A breaking (reflowable) space.
space :: Doc a
space = BreakingSpace

-- | A carriage return.  Does nothing if we're at the beginning of
-- a line; otherwise inserts a newline.
cr :: Doc a
cr = CarriageReturn

-- | Inserts a blank line unless one exists already.
-- (@blankline <> blankline@ has the same effect as @blankline@.
blankline :: Doc a
blankline = BlankLines 1

-- | Inserts blank lines unless they exist already.
-- (@blanklines m <> blanklines n@ has the same effect as @blanklines (max m n)@.
blanklines :: Int -> Doc a
blanklines = BlankLines

-- | Uses the specified string as a prefix for every line of
-- the inside document (except the first, if not at the beginning
-- of the line).
prefixed :: IsString a => String -> Doc a -> Doc a
prefixed pref doc
  | isEmpty doc = Empty
  | otherwise   = Prefixed (fromString pref) doc

-- | Makes a 'Doc' flush against the left margin.
flush :: Doc a -> Doc a
flush doc
  | isEmpty doc = Empty
  | otherwise   = Flush doc

-- | Indents a 'Doc' by the specified number of spaces.
nest :: IsString a => Int -> Doc a -> Doc a
nest ind = prefixed (replicate ind ' ')

-- | A hanging indent. @hang ind start doc@ prints @start@,
-- then @doc@, leaving an indent of @ind@ spaces on every
-- line but the first.
hang :: IsString a => Int -> Doc a -> Doc a -> Doc a
hang ind start doc = start <> nest ind doc

-- | @beforeNonBlank d@ conditionally includes @d@ unless it is
-- followed by blank space.
beforeNonBlank :: Doc a -> Doc a
beforeNonBlank = BeforeNonBlank

-- | Makes a 'Doc' non-reflowable.
nowrap :: IsString a => Doc a -> Doc a
nowrap = mconcat . map replaceSpace . unfoldD
  where replaceSpace BreakingSpace = Text 1 $ fromString " "
        replaceSpace x             = x

-- | Content to print only if it comes at the beginning of a line,
-- to be used e.g. for escaping line-initial `.` in roff man.
afterBreak :: Text -> Doc a
afterBreak = AfterBreak

-- | Returns the width of a 'Doc'.
offset :: (IsString a, HasChars a) => Doc a -> Int
offset (Text n _) = n
offset (Block n _) = n
offset (VFill n _) = n
offset Empty = 0
offset CarriageReturn = 0
offset NewLine = 0
offset (BlankLines _) = 0
offset d = maximum (0 : map realLength (splitLines (render Nothing d)))

-- | Returns the minimal width of a 'Doc' when reflowed at breakable spaces.
minOffset :: HasChars a => Doc a -> Int
minOffset (Text n _) = n
minOffset (Block n _) = n
minOffset (VFill n _) = n
minOffset Empty = 0
minOffset CarriageReturn = 0
minOffset NewLine = 0
minOffset (BlankLines _) = 0
minOffset d = maximum (0 : map realLength (splitLines (render (Just 0) d)))

-- | Returns the column that would be occupied by the last
-- laid out character (assuming no wrapping).
updateColumn :: HasChars a => Doc a -> Int -> Int
updateColumn (Text !n _) !k = k + n
updateColumn (Block !n _) !k = k + n
updateColumn (VFill !n _) !k = k + n
updateColumn Empty _ = 0
updateColumn CarriageReturn _ = 0
updateColumn NewLine _ = 0
updateColumn (BlankLines _) _ = 0
updateColumn d !k =
  case splitLines (render Nothing d) of
    []   -> k
    [t]  -> k + realLength t
    ts   -> realLength $ last ts

-- | @lblock n d@ is a block of width @n@ characters, with
-- text derived from @d@ and aligned to the left.
lblock :: HasChars a => Int -> Doc a -> Doc a
lblock = block id

-- | Like 'lblock' but aligned to the right.
rblock :: HasChars a => Int -> Doc a -> Doc a
rblock w = block (\s -> replicateChar (w - realLength s) ' ' <> s) w

-- | Like 'lblock' but aligned centered.
cblock :: HasChars a => Int -> Doc a -> Doc a
cblock w = block (\s -> replicateChar ((w - realLength s) `div` 2) ' ' <> s) w

-- | Returns the height of a block or other 'Doc'.
height :: HasChars a => Doc a -> Int
height = length . splitLines . render Nothing

block :: HasChars a => (a -> a) -> Int -> Doc a -> Doc a
block filler width d
  | width < 1 && not (isEmpty d) = block filler 1 d
  | otherwise                    = Block width ls
     where
       ls = map filler $ chop width $ render (Just width) d

-- | An expandable border that, when placed next to a box,
-- expands to the height of the box.  Strings cycle through the
-- list provided.
vfill :: HasChars a => a -> Doc a
vfill t = VFill (realLength t) t

chop :: HasChars a => Int -> a -> [a]
chop n =
   concatMap chopLine . removeFinalEmpty . map addRealLength . splitLines
 where
   removeFinalEmpty xs = case lastMay xs of
                           Just (0, _) -> initSafe xs
                           _           -> xs
   addRealLength l = (realLength l, l)
   chopLine (len, l)
     | len <= n  = [l]
     | otherwise = map snd $
                    foldrChar
                     (\c ls ->
                       let clen = charWidth c
                           cs = replicateChar 1 c
                        in case ls of
                             (len', l'):rest
                               | len' + clen > n ->
                                   (clen, cs):(len', l'):rest
                               | otherwise ->
                                   (len' + clen, cs <> l'):rest
                             [] -> [(clen, cs)]) [] l

-- | Encloses a 'Doc' inside a start and end 'Doc'.
inside :: Doc a -> Doc a -> Doc a -> Doc a
inside start end contents =
  start <> contents <> end

-- | Puts a 'Doc' in curly braces.
braces :: HasChars a => Doc a -> Doc a
braces = inside (char '{') (char '}')

-- | Puts a 'Doc' in square brackets.
brackets :: HasChars a => Doc a -> Doc a
brackets = inside (char '[') (char ']')

-- | Puts a 'Doc' in parentheses.
parens :: HasChars a => Doc a -> Doc a
parens = inside (char '(') (char ')')

-- | Wraps a 'Doc' in single quotes.
quotes :: HasChars a => Doc a -> Doc a
quotes = inside (char '\'') (char '\'')

-- | Wraps a 'Doc' in double quotes.
doubleQuotes :: HasChars a => Doc a -> Doc a
doubleQuotes = inside (char '"') (char '"')

-- | Returns width of a character in a monospace font:  0 for a combining
-- character, 1 for a regular character, 2 for an East Asian wide character.
charWidth :: Char -> Int
charWidth c = maybe 1 (specificWidth . snd) $ IM.lookupLE (ord c) unicodeWidthMap

-- | Get real length of string, taking into account combining and double-wide
-- characters.
realLength :: HasChars a => a -> Int
realLength = realLengthWith updateMatchState

-- | Get real length of string, taking into account combining and double-wide
-- characters, without taking any shortcuts. This should give the same answer
-- as 'updateMatchState', but will be slower. It is here to test that the
-- shortcuts are implemented correctly.
realLengthNoShortcut :: HasChars a => a -> Int
realLengthNoShortcut = realLengthWith updateMatchStateNoShortcut

-- | Get real length of string, taking into account combining and double-wide
-- characters, using the given accumulator.
realLengthWith :: HasChars a => (MatchState -> Char -> MatchState) -> a -> Int
realLengthWith f = extractLength . foldlChar f (MatchState True 0 0 mempty)
  where
    extractLength (MatchState _ tot w _) = tot + w

-- | Update a 'MatchState' by processing a character.
updateMatchState :: MatchState -> Char -> MatchState
updateMatchState (MatchState first tot _ Nothing) !c
    -- For efficiency, we isolate commonly used portions of the basic
    -- multilingual plane that do not have emoji in them.
    -- Maximum contiguous range containing ASCII alphabetic characters and no emoji
    | c <= '\x00A8'                                   = MatchState False (tot + 1) 0 Nothing
    -- Combining characters have width 0
    | c >= '\x0300' && c <= '\x036F'                  = MatchState False (if first then tot + 1 else tot) 0 Nothing
    -- A block of width 1
    | c >= '\x0370' && c <= '\x10FC'                  = MatchState False (tot + 1) 0 Nothing
    -- Hexagrams are width 1
    | c >= '\x4DC0' && c <= '\x4DFF'                  = MatchState False (tot + 1) 0 Nothing
    -- Maximum contiguous range of width 2 with no emoji containing CJK
    | c >= '\x329a' && c <= '\xA4C6'                  = MatchState False (tot + 2) 0 Nothing
    -- An ambiguous block; TODO: should be width 2 if surrounded by wide, 1 otherwise
    | c >= '\x3248' && c <= '\x324F'                  = MatchState False (tot + 1) 0 Nothing
    -- A width 1 straggler
    | c == '\x303F'                                   = MatchState False (tot + 1) 0 Nothing
updateMatchState s c = updateMatchStateNoShortcut s c

-- | Update a 'MatchState' by processing a character, without taking any
-- shortcuts. This should give the same answer as 'updateMatchState', but will
-- be slower. It is here to test that the shortcuts are implemented correctly.
updateMatchStateNoShortcut :: MatchState -> Char -> MatchState
updateMatchStateNoShortcut (MatchState first tot _ Nothing) !c =
    case IM.lookupLE oc unicodeWidthMap of
        -- If there is a specific match, record the tentative width, the map of
        -- continuations, and move to the next character
        Just (!oc', SpecificMatch r w m) | oc == oc' -> MatchState False tot (fromMaybe r w) (Just m)
        -- If there is only a range match, record the total width and move to
        -- the next character
        Just (!_, !match) -> let r = rangeWidth match
                                 -- If the string starts with a combining character.  Since there is no
                                 -- preceding character, we count 0 width as 1 in this one case:
                                 r' = if first && r == 0 then 1 else r
                              in MatchState False (tot + r') 0 Nothing
        -- M.lookupLE should not fail
        Nothing -> MatchState False (tot + 1) 0 Nothing
  where
    oc = ord c
updateMatchStateNoShortcut (MatchState _ tot w (Just !m)) !c
    -- Skin tone modifiers and variation modifiers modify the emoji up to this
    -- point, so can be discarded. However, they always make it width 2, so we
    -- set the tentative width to 2.
    | isEmojiModifier c || isEmojiVariation c = MatchState False tot 2 (Just m)
    -- Zero width joiners will join two emoji together, so let's discard the state and parse the next emoji
    | isEmojiJoiner c = MatchState False tot 2 Nothing
    -- Otherwise, lookup the emoji continuations
    | otherwise = case IM.lookup (ord c) m of
        -- Continuations match, move to the next step with new continuations
        Just (Emoji ew m') -> MatchState False tot ew (Just m')
        -- No continuations match, use the tentative width and process c without continuations
        -- I guess we use shortcuts here; that's probably fine.
        Nothing -> updateMatchState (MatchState False (tot + w) 0 Nothing) c

-- | Keeps track of state in length calculations, determining whether we're at
-- the first character, the width so far, the tentative width for this group,
-- and the Map for possible emoji continuations.
data MatchState = MatchState !Bool !Int !Int !(Maybe EmojiMap)

-- | A possible match for unicode characters; either within a range block, or a
-- specific match with a block range width, possibly a specific width, and a map of
-- continuations.
data UnicodeWidthMatch
    = RangeSeparator !Int                         -- This code point marks the boundary of a range
    | SpecificMatch !Int !(Maybe Int) !EmojiMap   -- This code point has a specific emoji with continuations
  deriving (Show)

instance Semigroup UnicodeWidthMatch where
    (SpecificMatch r w1 m1) <> (SpecificMatch _ w2 m2) = SpecificMatch r w $ concatEmojiMap m1 m2
      where
        w = getSum <$> (Sum <$> w1) <> (Sum <$> w2)
    s <> _ = s

-- | The width of the block in which the character lies, ignoring specific
-- matches.
rangeWidth :: UnicodeWidthMatch -> Int
rangeWidth (RangeSeparator !r)    = r
rangeWidth (SpecificMatch !r !_ !_) = r

-- | The specific width of a character.
specificWidth :: UnicodeWidthMatch -> Int
specificWidth (RangeSeparator r)    = r
specificWidth (SpecificMatch r w _) = fromMaybe r w

-- | Checks whether a character is a skin tone modifier
isEmojiModifier :: Char -> Bool
isEmojiModifier c = c >= '\x1F3FB' && c <= '\x1F3FF'

-- | Checks whether a character is an emoji variation modifier.
isEmojiVariation :: Char -> Bool
isEmojiVariation c = c == '\xFE0F'

-- | Checks whether a character is an emoji joiner.
isEmojiJoiner :: Char -> Bool
isEmojiJoiner c = c == '\x200D'

-- | A map for looking up the width of Unicode text.
unicodeWidthMap :: IM.IntMap UnicodeWidthMatch
unicodeWidthMap =
    foldr addEmoji unicodeRangeMap
    . filter (maybe True (not . isKeypad . fst) . T.uncons)  -- Keypad emoji can be handles by base rules
    $ filter (not . T.any isEmojiModifier)                   -- Emoji modifiers are inferred from the base emoji
    baseEmojis
  where
    isKeypad c = isDigit c || c == '*' || c == '#'

-- | Denotes the contiguous ranges of Unicode characters which have a given
-- width: 1 for a regular character, 2 for an East Asian wide character. Emoji
-- have different widths and lie within some of these blocks. And the emoji
-- will be added later.
unicodeRangeMap :: IM.IntMap UnicodeWidthMatch
unicodeRangeMap = IM.fromList $ map (\(c, x) -> (ord c, x))
    [ ('\x0000', RangeSeparator 1)
    , ('\x0300', RangeSeparator 0)  -- combining
    , ('\x0370', RangeSeparator 1)
    , ('\x1100', RangeSeparator 2)
    , ('\x1160', RangeSeparator 1)
    , ('\x11A3', RangeSeparator 2)
    , ('\x11A8', RangeSeparator 1)
    , ('\x11FA', RangeSeparator 2)
    , ('\x1200', RangeSeparator 1)
    , ('\x1AB0', RangeSeparator 0)  -- combining
    , ('\x1B00', RangeSeparator 1)
    , ('\x1DC0', RangeSeparator 0)  -- combining
    , ('\x1E00', RangeSeparator 1)
    , ('\x200B', RangeSeparator 0)  -- zero-width characters and directional overrides
    , ('\x2010', RangeSeparator 1)
    , ('\x20D0', RangeSeparator 0)  -- combining
    , ('\x2100', RangeSeparator 1)
    , ('\x2329', RangeSeparator 2)
    , ('\x232B', RangeSeparator 1)
    , ('\x2E80', RangeSeparator 2)
    , ('\x303F', RangeSeparator 1)
    , ('\x3041', RangeSeparator 2)
    , ('\x3248', RangeSeparator 1)  -- ambiguous
    , ('\x3250', RangeSeparator 2)
    , ('\x4DC0', RangeSeparator 1)
    , ('\x4E00', RangeSeparator 2)
    , ('\xA4D0', RangeSeparator 1)
    , ('\xA960', RangeSeparator 2)
    , ('\xA980', RangeSeparator 1)
    , ('\xAC00', RangeSeparator 2)
    , ('\xD800', RangeSeparator 1)
    , ('\xE000', RangeSeparator 1)  -- ambiguous
    , ('\xF900', RangeSeparator 2)
    , ('\xFB00', RangeSeparator 1)
    , ('\xFE00', RangeSeparator 1)  -- ambiguous
    , ('\xFE10', RangeSeparator 2)
    , ('\xFE20', RangeSeparator 0)  -- combining
    , ('\xFE30', RangeSeparator 2)
    , ('\xFE70', RangeSeparator 1)
    , ('\xFF01', RangeSeparator 2)
    , ('\xFF61', RangeSeparator 1)
    , ('\x1B000', RangeSeparator 2)
    , ('\x1D000', RangeSeparator 1)
    , ('\x1F200', RangeSeparator 2)
    , ('\x1F300', RangeSeparator 1)
    , ('\x1F3FB', RangeSeparator 2)  -- skin tone modifiers
    , ('\x1F400', RangeSeparator 1)
    , ('\x20000', RangeSeparator 2)
    , ('\x3FFFD', RangeSeparator 1)
    ]

type EmojiMap = IM.IntMap Emoji
data Emoji = Emoji !Int !EmojiMap
  deriving (Show)

concatEmojiMap :: EmojiMap -> EmojiMap -> EmojiMap
concatEmojiMap = IM.unionWith (\(Emoji w e1) (Emoji _ e2) -> Emoji w $ concatEmojiMap e1 e2)

emojiToMatch :: IM.IntMap UnicodeWidthMatch -> NonEmpty Char -> UnicodeWidthMatch
emojiToMatch m (x:|xs) = SpecificMatch r w . emojiToMap $ filter (not . isEmojiVariation) xs
  where
    r = maybe 1 (rangeWidth . snd) $ IM.lookupLT (ord x) m
    -- If it is a single code point emoji, it is of width 2. Otherwise, don't
    -- overwrite the range width.
    w = if null xs then Just 2 else Nothing

addEmoji :: Text -> IM.IntMap UnicodeWidthMatch -> IM.IntMap UnicodeWidthMatch
addEmoji !emoji !m = case T.unpack emoji of
    []   -> m
    x:xs -> IM.insertWith (<>) (ord x) (emojiToMatch m (x:|xs)) m

emojiToMap :: String -> EmojiMap
emojiToMap []     = mempty
emojiToMap (x:xs) = IM.singleton (ord x) . Emoji 2 $ emojiToMap xs
