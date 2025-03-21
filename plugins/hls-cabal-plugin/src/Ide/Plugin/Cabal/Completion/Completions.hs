{-# LANGUAGE OverloadedStrings #-}

module Ide.Plugin.Cabal.Completion.Completions (contextToCompleter, getContext, getCabalPrefixInfo) where

import           Control.Lens                                  ((^.))
import           Control.Monad.IO.Class                        (MonadIO)
import           Data.List.NonEmpty                            (NonEmpty)
import qualified Data.List.NonEmpty                            as NE
import qualified Data.Map                                      as Map
import qualified Data.Text                                     as T
import           Development.IDE                               as D
import qualified Development.IDE.Plugin.Completions.Types      as Ghcide
import qualified Distribution.Fields                           as Syntax
import qualified Distribution.Parsec.Position                  as Syntax
import           Ide.Plugin.Cabal.Completion.CabalFields
import           Ide.Plugin.Cabal.Completion.Completer.Simple
import           Ide.Plugin.Cabal.Completion.Completer.Snippet
import           Ide.Plugin.Cabal.Completion.Completer.Types   (Completer)
import           Ide.Plugin.Cabal.Completion.Data
import           Ide.Plugin.Cabal.Completion.Types
import qualified Language.LSP.Protocol.Lens                    as JL
import qualified System.FilePath                               as FP
import           System.FilePath                               (takeBaseName)

-- ----------------------------------------------------------------
-- Public API for Completions
-- ----------------------------------------------------------------

-- | Takes information about the completion context within the file
--  and finds the correct completer to be applied.
contextToCompleter :: Context -> Completer
-- if we are in the top level of the cabal file and not in a keyword context,
-- we can write any top level keywords or a stanza declaration
contextToCompleter (TopLevel, None) =
  snippetCompleter
    <> ( constantCompleter $
           Map.keys (cabalVersionKeyword <> cabalKeywords) ++ Map.keys stanzaKeywordMap
       )
-- if we are in a keyword context in the top level,
-- we look up that keyword in the top level context and can complete its possible values
contextToCompleter (TopLevel, KeyWord kw) =
  case Map.lookup kw (cabalVersionKeyword <> cabalKeywords) of
    Nothing -> errorNoopCompleter (LogUnknownKeyWordInContextError kw)
    Just l  -> l
-- if we are in a stanza and not in a keyword context,
-- we can write any of the stanza's keywords or a stanza declaration
contextToCompleter (Stanza s _, None) =
  case Map.lookup s stanzaKeywordMap of
    Nothing -> errorNoopCompleter (LogUnknownStanzaNameInContextError s)
    Just l  -> constantCompleter $ Map.keys l
-- if we are in a stanza's keyword's context we can complete possible values of that keyword
contextToCompleter (Stanza s _, KeyWord kw) =
  case Map.lookup s stanzaKeywordMap of
    Nothing -> errorNoopCompleter (LogUnknownStanzaNameInContextError s)
    Just m -> case Map.lookup kw m of
      Nothing -> errorNoopCompleter (LogUnknownKeyWordInContextError kw)
      Just l  -> l

-- | Takes prefix info about the previously written text
--  and a rope (representing a file), returns the corresponding context.
--
--  Can return Nothing if an error occurs.
--
--  TODO: first line can only have cabal-version: keyword
getContext :: (MonadIO m) => Recorder (WithPriority Log) -> CabalPrefixInfo -> [Syntax.Field Syntax.Position] -> m Context
getContext recorder prefInfo fields = do
    let ctx = findCursorContext cursor (NE.singleton (0, TopLevel)) (completionPrefix prefInfo) fields
    logWith recorder Debug $ LogCompletionContext ctx
    pure ctx
  where
    cursor = lspPositionToCabalPosition (completionCursorPosition prefInfo)

-- | Takes information about the current file's file path,
--  and the cursor position in the file; and builds a CabalPrefixInfo
--  with the prefix up to that cursor position.
--  Checks whether a suffix needs to be completed
--  and calculates the range in the document
--  where the completion action should be applied.
getCabalPrefixInfo :: FilePath -> Ghcide.PosPrefixInfo -> CabalPrefixInfo
getCabalPrefixInfo fp prefixInfo =
  CabalPrefixInfo
    { completionPrefix = completionPrefix',
      isStringNotation = mkIsStringNotation separator afterCursorText,
      completionCursorPosition = Ghcide.cursorPos prefixInfo,
      completionRange = Range completionStart completionEnd,
      completionWorkingDir = FP.takeDirectory fp,
      completionFileName = T.pack $ takeBaseName fp
    }
  where
    completionEnd = Ghcide.cursorPos prefixInfo
    completionStart =
      Position
        (_line completionEnd)
        (_character completionEnd - (fromIntegral $ T.length completionPrefix'))
    (beforeCursorText, afterCursorText) = T.splitAt cursorColumn $ Ghcide.fullLine prefixInfo
    completionPrefix' = T.takeWhileEnd (not . (`elem` stopConditionChars)) beforeCursorText
    separator =
      -- if there is an opening apostrophe before the cursor in the line somewhere,
      -- everything after that apostrophe is the completion prefix
      if odd $ T.count "\"" beforeCursorText
        then '\"'
        else ' '
    cursorColumn = fromIntegral $ Ghcide.cursorPos prefixInfo ^. JL.character
    stopConditionChars = separator : [',', ':']

    -- \| Takes the character occurring exactly before,
    --  and the text occurring after the item to be completed and
    --  returns whether the item is already surrounded by apostrophes.
    --
    --  Example: (@|@ indicates the cursor position)
    --
    --  @"./src|@ would call @'\"'@ @""@ and result in Just LeftSide
    --
    --  @"./src|"@ would call @'\"'@ @'\"'@ and result in Just Surrounded
    --
    mkIsStringNotation :: Char -> T.Text -> Maybe Apostrophe
    mkIsStringNotation '\"' restLine
      | Just ('\"', _) <- T.uncons restLine = Just Surrounded
      | otherwise = Just LeftSide
    mkIsStringNotation _ _ = Nothing

-- ----------------------------------------------------------------
-- Implementation Details
-- ----------------------------------------------------------------

findCursorContext ::
  Syntax.Position ->
  -- ^ The cursor position we look for in the fields
  NonEmpty (Int, StanzaContext) ->
  -- ^ A stack of current stanza contexts and their starting line numbers
  T.Text ->
  -- ^ The cursor's prefix text
  [Syntax.Field Syntax.Position] ->
  -- ^ The fields to traverse
  Context
findCursorContext cursor parentHistory prefixText fields =
  case findFieldSection cursor fields of
    Nothing -> (snd $ NE.head parentHistory, None)
    -- We found the most likely section. Now, are we starting a new section or are we completing an existing one?
    Just field@(Syntax.Field _ _) -> classifyFieldContext parentHistory cursor field
    Just section@(Syntax.Section _ args sectionFields)
      | inSameLineAsSectionName section -> (stanzaCtx, None) -- TODO: test whether keyword in same line is parsed correctly
      | getFieldName section `elem` conditionalKeywords -> findCursorContext cursor parentHistory prefixText sectionFields -- Ignore if conditionals, they are not real sections
      | otherwise ->
          findCursorContext cursor
            (NE.cons (Syntax.positionCol (getAnnotation section) + 1, Stanza (getFieldName section) (getOptionalSectionName args)) parentHistory)
            prefixText sectionFields
    where
        inSameLineAsSectionName section = Syntax.positionRow (getAnnotation section) == Syntax.positionRow cursor
        stanzaCtx = snd $ NE.head parentHistory
        conditionalKeywords = ["if", "elif", "else"]

-- | Finds the cursor's context, where the cursor is already found to be in a specific field
--
-- Due to the way the field context is recognised for incomplete cabal files,
-- an incomplete keyword is also recognised as a field, therefore we need to determine
-- the specific context as we could still be in a stanza context in this case.
classifyFieldContext :: NonEmpty (Int, StanzaContext) -> Syntax.Position -> Syntax.Field Syntax.Position -> Context
classifyFieldContext ctx cursor field
  -- the cursor is not indented enough to be within the field
  -- but still indented enough to be within the stanza
  | cursorColumn <= fieldColumn && minIndent <= cursorColumn = (stanzaCtx, None)
  -- the cursor is not in the current stanza's context as it is not indented enough
  | cursorColumn < minIndent = findStanzaForColumn cursorColumn ctx
  | cursorIsInFieldName = (stanzaCtx, None)
  | cursorIsBeforeFieldName = (stanzaCtx, None)
  | otherwise = (stanzaCtx, KeyWord (getFieldName field <> ":"))
  where
    (minIndent, stanzaCtx) = NE.head ctx

    cursorIsInFieldName = inSameLineAsFieldName &&
      fieldColumn <= cursorColumn &&
      cursorColumn <= fieldColumn + T.length (getFieldName field)

    cursorIsBeforeFieldName = inSameLineAsFieldName &&
      cursorColumn < fieldColumn

    inSameLineAsFieldName = Syntax.positionRow (getAnnotation field) == Syntax.positionRow cursor

    cursorColumn = Syntax.positionCol cursor
    fieldColumn = Syntax.positionCol (getAnnotation field)
