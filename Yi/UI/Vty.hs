-- Copyright (C) 2007-8 JP Bernardy
-- Copyright (C) 2004-5 Don Stewart - http://www.cse.unsw.edu.au/~dons
-- Originally derived from: riot/UI.hs Copyright (c) Tuomo Valkonen 2004.


-- | This module defines a user interface implemented using vty.

module Yi.UI.Vty (start) where

import Yi.Prelude hiding ((<|>))
import Prelude (map, take, zip, repeat, length, break, splitAt)
import Control.Arrow
import Control.Concurrent
import Control.Exception
import Control.Monad (forever)
import Control.Monad.State (runState, State, gets, modify, get, put)
import Control.Monad.Trans (liftIO, MonadIO)
import Data.Char (ord,chr)
import Data.Foldable
import Data.IORef
import Data.List (partition, sort, nub)
import qualified Data.Map as M
import Data.Maybe
import Data.Traversable
import System.Exit
import System.Posix.Signals         ( raiseSignal, sigTSTP )
import Yi.Buffer
import Yi.Buffer.Implementation
import Yi.Buffer.Region
import Yi.Buffer.HighLevel
import Yi.Config
import Yi.Editor
import Yi.Event
import Yi.Monad
import Yi.Regex (SearchExp)
import Yi.Style
import Yi.WindowSet as WS
import qualified Data.ByteString.Char8 as B
import qualified Yi.UI.Common as Common
import Yi.Config
import Yi.Window
import Yi.Style as Style
import Graphics.Vty as Vty hiding (refresh)
import qualified Graphics.Vty as Vty

import Yi.UI.Utils
import Yi.UI.TabBar
import Yi.Syntax (Stroke)
import Yi.Buffer.Indent (indentSettingsB)

------------------------------------------------------------------------

data Rendered = 
    Rendered {
              picture :: !Image           -- ^ the picture currently displayed.
             ,cursor  :: !(Maybe (Int,Int)) -- ^ cursor point on the above
             }




data UI = UI { 
              vty       :: Vty              -- ^ Vty
             ,scrsize   :: IORef (Int,Int)  -- ^ screen size
             ,uiThread  :: ThreadId
             ,uiRefresh :: MVar ()
             ,uiEditor  :: IORef Editor     -- ^ Copy of the editor state, local to the UI
             ,config  :: Config
             }

mkUI :: UI -> Common.UI
mkUI ui = Common.dummyUI 
  {
   Common.main           = main ui,
   Common.end            = end ui,
   Common.suspend        = raiseSignal sigTSTP,
   Common.refresh        = scheduleRefresh ui,
   Common.prepareAction  = prepareAction ui,
   Common.userForceRefresh = userForceRefresh ui
  }

-- | Initialise the ui
start :: UIBoot
start cfg ch _outCh editor = do
  liftIO $ do 
          v <- mkVty
          (x0,y0) <- Vty.getSize v
          sz <- newIORef (y0,x0)
          -- fork input-reading thread. important to block *thread* on getKey
          -- otherwise all threads will block waiting for input
          t <- myThreadId
          tuiRefresh <- newEmptyMVar
          editorRef <- newIORef editor
          let result = UI v sz t tuiRefresh editorRef cfg
              -- | Action to read characters into a channel
              getcLoop = forever $ getKey >>= ch

              -- | Read a key. UIs need to define a method for getting events.
              getKey = do 
                event <- getEvent v
                case event of 
                  (EvResize x y) -> do logPutStrLn $ "UI: EvResize: " ++ show (x,y)
                                       writeIORef sz (y,x) >> readRef (uiEditor result) >>= Yi.UI.Vty.refresh result >> getKey
                  _ -> return (fromVtyEvent event)
          forkIO $ getcLoop
          return (mkUI result)
        

main :: UI -> IO ()
main ui = do
  let
      -- | When the editor state isn't being modified, refresh, then wait for
      -- it to be modified again. 
      refreshLoop :: IO ()
      refreshLoop = forever $ do 
                      logPutStrLn "waiting for refresh"
                      takeMVar (uiRefresh ui)
                      handleJust ioErrors (\except -> do 
                                             logPutStrLn "refresh crashed with IO Error"
                                             logError $ show $ except)
                                     (readRef (uiEditor ui) >>= refresh ui >> return ())
  readRef (uiEditor ui) >>= scheduleRefresh ui
  logPutStrLn "refreshLoop started"
  refreshLoop
  

-- | Clean up and go home
end :: UI -> IO ()
end i = do  
  Vty.shutdown (vty i)
  throwTo (uiThread i) (ExitException ExitSuccess)

fromVtyEvent :: Vty.Event -> Yi.Event.Event
fromVtyEvent (EvKey Vty.KBackTab mods) = Event Yi.Event.KTab (sort $ nub $ Yi.Event.MShift : map fromVtyMod mods)
fromVtyEvent (EvKey k mods) = Event (fromVtyKey k) (sort $ map fromVtyMod mods)
fromVtyEvent _ = error "fromVtyEvent: unsupported event encountered."


fromVtyKey :: Vty.Key -> Yi.Event.Key
fromVtyKey (Vty.KEsc     ) = Yi.Event.KEsc      
fromVtyKey (Vty.KFun x   ) = Yi.Event.KFun x    
fromVtyKey (Vty.KPrtScr  ) = Yi.Event.KPrtScr   
fromVtyKey (Vty.KPause   ) = Yi.Event.KPause    
fromVtyKey (Vty.KASCII '\t') = Yi.Event.KTab
fromVtyKey (Vty.KASCII c ) = Yi.Event.KASCII c  
fromVtyKey (Vty.KBS      ) = Yi.Event.KBS       
fromVtyKey (Vty.KIns     ) = Yi.Event.KIns      
fromVtyKey (Vty.KHome    ) = Yi.Event.KHome     
fromVtyKey (Vty.KPageUp  ) = Yi.Event.KPageUp   
fromVtyKey (Vty.KDel     ) = Yi.Event.KDel      
fromVtyKey (Vty.KEnd     ) = Yi.Event.KEnd      
fromVtyKey (Vty.KPageDown) = Yi.Event.KPageDown 
fromVtyKey (Vty.KNP5     ) = Yi.Event.KNP5      
fromVtyKey (Vty.KUp      ) = Yi.Event.KUp       
fromVtyKey (Vty.KMenu    ) = Yi.Event.KMenu     
fromVtyKey (Vty.KLeft    ) = Yi.Event.KLeft     
fromVtyKey (Vty.KDown    ) = Yi.Event.KDown     
fromVtyKey (Vty.KRight   ) = Yi.Event.KRight    
fromVtyKey (Vty.KEnter   ) = Yi.Event.KEnter    

fromVtyMod :: Vty.Modifier -> Yi.Event.Modifier
fromVtyMod Vty.MShift = Yi.Event.MShift
fromVtyMod Vty.MCtrl  = Yi.Event.MCtrl
fromVtyMod Vty.MMeta  = Yi.Event.MMeta
fromVtyMod Vty.MAlt   = Yi.Event.MMeta

prepareAction :: UI -> IO (EditorM ())
prepareAction ui = do
  (yss,xss) <- readRef (scrsize ui)
  return $ do
    ts <- getA tabsA
    let hasTabBar = WS.size ts > 1
        tabBarHeight = if hasTabBar then 1 else 0
    modifyWindows (computeHeights (yss - tabBarHeight))
    e <- get
    let ws = windows e
        renderSeq = fmap (scrollAndRenderWindow (configUI $ config ui) xss) (WS.withFocus ws)
    sequence_ renderSeq


-- | Redraw the entire terminal from the UI.
-- Among others, this re-computes the heights and widths of all the windows.

-- Two points remain: horizontal scrolling, and tab handling.
refresh :: UI -> Editor -> IO Editor
refresh ui e = do
  let ws = windows e
      hasTabBar = WS.size (tabs e) > 1
      tabBarHeight = if hasTabBar then 1 else 0
      windowStartY = if hasTabBar then 1 else 0
  logPutStrLn "refreshing screen."
  (yss,xss) <- readRef (scrsize ui)
  let ws' = computeHeights (yss - tabBarHeight) ws
      cmd = statusLine e
      renderSeq = fmap (scrollAndRenderWindow (configUI $ config ui) xss) (WS.withFocus ws')
      (e', renders) = runEditor (config ui) (sequence renderSeq) e

  let startXs = scanrT (+) windowStartY (fmap height ws')
      wImages = fmap picture renders
      statusBarStyle = window $ configStyle $ configUI $ config $ ui
      tabBarImages = renderTabBar e' ui xss
  WS.debug "Drawing: " ws'
  logPutStrLn $ "startXs: " ++ show startXs
  Vty.update (vty $ ui) 
      pic {pImage = vertcat tabBarImages 
                    <->
                    vertcat (toList wImages) 
                    <-> 
                    withStyle statusBarStyle (take xss $ cmd ++ repeat ' '),
           pCursor = case cursor (WS.current renders) of
                       Just (y,x) -> Cursor x (y + WS.current startXs) 
                       -- Add the position of the window to the position of the cursor
                       Nothing -> NoCursor
                       -- This case can occur if the user resizes the window. 
                       -- Not really nice, but upon the next refresh the cursor will show.
                       }

  return e'

{- Produces a possible empty list of images that represent the tab bar.
 - The current tab bar image is basic: A single horizontal line divided into a number of segments
 - equal to the number of tabs. Plus maybe a bit extra to make up for a screen width that is not a
 - multiple of the number of tabs.
 - The tab current in focus is indicated by a segment of spaces. 
 - While the out of focus tabs are all segments filled with # characters.
 - 
 - TODO: Provide a hint as to what the tabs contain.
 - TODO: If there are too many tabs to be contained on a single line spill over onto the next line.
 -}
renderTabBar :: Editor -> UI -> Int -> [Image]
renderTabBar e ui xss = 
    let tabCount = WS.size $ tabs e
    in if tabCount > 1
        then 
            let tabWidth = xss `div` tabCount
                descr = tabBarDescr e (tabWidth - 5) (configStyle $ configUI $ config $ ui)
                tabImages = fmap (tabToVtyImage tabWidth) descr
                -- If the screen width is not a multiple of the tab width then characters have to be
                -- added to make them the same. Otherwise Vty will error out when trying to
                -- vertically concat two images with different widths.
                extraCount = xss - (tabWidth * WS.size tabImages)
                extraStyle = modeline $ configStyle $ configUI $ config $ ui
                extraImage = withStyle extraStyle $ replicate extraCount '#'
                finalImage = if extraCount /= 0
                    then foldr (<|>) extraImage tabImages
                    else foldr1 (<|>) tabImages
            in [finalImage]
        else []
    where 
        -- From an abstract description of a tab to a VTY image of the tab.
        tabToVtyImage width (TabDescr txt sty inFocus) = 
            let pad = replicate (width - length txt - 5) ' '
                spacers = if inFocus then (">>", "<<") else ("  ", "  ")
            in withStyle sty $ (fst spacers) ++ txt ++ (snd spacers) ++ pad ++ "|"

scanrT :: (Int -> Int -> Int) -> Int -> WindowSet Int -> WindowSet Int
scanrT (+*+) k t = fst $ runState (mapM f t) k
    where f x = do s <- get
                   let s' = s +*+ x
                   put s'
                   return s
           

-- | Scrolls the window to show the point if needed, and return a rendered wiew of the window.
scrollAndRenderWindow :: UIConfig -> Int -> (Window, Bool) -> EditorM Rendered
scrollAndRenderWindow cfg width (win,hasFocus) = do 
    e <- get
    let sty = configStyle cfg
        b = findBufferWith (bufkey win) e
        
        ((pointDriven, inWindow), _) = runBuffer win b $ do point <- pointB
                                                            (,) <$> getA pointDriveA <*> pointInWindowB point
        b' = if inWindow then b else 
                if pointDriven then moveWinTosShowPoint b win else showPoint b
        (rendered, b'') = drawWindow cfg (regex e) b' sty hasFocus width win
        showPoint buf = snd $ runBuffer win buf' $ do r <- winRegionB
                                                      p <- pointB
                                                      moveTo $ max (regionStart r) $ min (regionEnd r - 1) $ p
                                                      setA pointDriveA True -- revert to a point-driven behaviour
                      where (_,buf') = drawWindow cfg (regex e) buf sty hasFocus width win
                             -- this is merely to recompute the bos point.

    put e { buffers = M.insert (bufkey win) b'' (buffers e) }
    return rendered

-- | Draw a window
-- TODO: horizontal scrolling.
drawWindow :: UIConfig -> Maybe SearchExp -> FBuffer -> UIStyle -> Bool -> Int -> Window -> (Rendered, FBuffer)
drawWindow cfg mre b sty focused w win = (Rendered { picture = pict,cursor = cur}, b')
    where
        notMini = not (isMini win)
        -- off reserves space for the mode line. The mini window does not have a mode line.
        off = if notMini then 1 else 0
        h' = height win - off
        wsty = attributesToAttr (appStyle (window sty)) attr
        selsty = attributesToAttr (appStyle (window sty)) attr
        eofsty = eof sty
        (selreg, _) = runBuffer win b getSelectRegionB
        (point, _) = runBuffer win b pointB
        (eofPoint, _) = runBuffer win b sizeB
        sz = Size (w*h')
        -- Work around a problem with the mini window never displaying it's contents due to a
        -- fromMark that is always equal to the end of the buffer contents.
        (Just (WinMarks fromM _ _ toM), _) = runBuffer win b (getMarks win)
        fromMarkPoint = if notMini
                            then fst $ runBuffer win b (getMarkPointB fromM)
                            else Point 0
        (text, _)    = runBuffer win b (streamB Forward fromMarkPoint) -- read enough chars from the buffer.
        (strokes, _) = runBuffer win b (strokesRangesB  mre fromMarkPoint (fromMarkPoint +~ sz)) -- corresponding strokes
        colors = map (second (($ attr) . attributesToAttr)) (paintPicture defaultAttributes (map (map (toVtyStroke sty)) strokes))
        bufData = -- trace (unlines (map show text) ++ unlines (map show $ concat strokes)) $ 
                  paintChars attr colors $ toIndexedString fromMarkPoint text
        (showSel, _) = runBuffer win b (gets highlightSelection)
        tabWidth = tabSize . fst $ runBuffer win b indentSettingsB
        prompt = if isMini win then name b else ""

        (rendered,toMarkPoint',cur) = drawText h' w
                                fromMarkPoint
                                point 
                                tabWidth
                                (if showSel then selreg else emptyRegion)
                                selsty wsty 
                                ([(c,(wsty, (-1))) | c <- prompt] ++ bufData ++ [(' ',(wsty, eofPoint))])
                             -- we always add one character which can be used to position the cursor at the end of file
        (_, b') = runBuffer win b (setMarkPointB toM toMarkPoint')
        (modeLine0, _) = runBuffer win b getModeLine
        modeLine = if notMini then Just modeLine0 else Nothing
        modeLines = map (withStyle (modeStyle sty) . take w . (++ repeat ' ')) $ maybeToList $ modeLine
        modeStyle = if focused then modelineFocused else modeline        
        filler = take w (configWindowFill cfg : repeat ' ')
    
        pict = vertcat (take h' (rendered ++ repeat (withStyle eofsty filler)) ++ modeLines)
  
-- | Renders text in a rectangle.
-- This also returns 
-- * the index of the last character fitting in the rectangle
-- * the position of the Point in (x,y) coordinates, if in the window.
drawText :: Int    -- ^ The height of the part of the window we are in
         -> Int    -- ^ The width of the part of the window we are in
         -> Point  -- ^ The position of the first character to draw
         -> Point  -- ^ The position of the cursor
         -> Int    -- ^ The number of spaces to represent a tab character with.
         -> Region -- ^ The selected region
         -> Vty.Attr   -- ^ The attribute with which to draw selected text
         -> Vty.Attr   -- ^ The attribute with which to draw the background
                   -- this is not used for drawing but only to compare
                   -- it against the selection attribute to avoid making
                   -- the selection invisible.
         -> [(Char,(Vty.Attr,Point))]  -- ^ The data to draw.
         -> ([Image], Point, Maybe (Int,Int))
drawText h w topPoint point tabWidth selreg selsty wsty bufData
    | h == 0 || w == 0 = ([], topPoint, Nothing)
    | otherwise        = (rendered_lines, bottomPoint, pntpos)
  where 

  lns0 = take h $ concatMap (wrapLine w) $ map (concatMap expandGraphic) $ take h $ lines' $ bufData

  bottomPoint = case lns0 of 
                 [] -> topPoint 
                 _ -> snd $ snd $ last $ last $ lns0

  pntpos = listToMaybe [(y,x) | (y,l) <- zip [0..] lns0, (x,(_char,(_attr,p))) <- zip [0..] l, p == point]

  -- fill lines with blanks, so the selection looks ok.
  rendered_lines = map fillColorLine lns0
  colorChar (c, (a, x)) = renderChar (pointStyle x a) c

  pointStyle :: Point -> Vty.Attr -> Vty.Attr
  pointStyle x a 
    | x == point          = a
    | x `inRegion` selreg 
      && selsty /= wsty   = selsty
    | otherwise           = a

  fillColorLine :: [(Char, (Vty.Attr, Point))] -> Image
  fillColorLine [] = renderHFill attr ' ' w
  fillColorLine l = horzcat (map colorChar l) 
                    <|>
                    renderHFill (pointStyle x a) ' ' (w - length l)
                    where (_,(a,x)) = last l

  -- | Cut a string in lines separated by a '\n' char. Note
  -- that we add a blank character where the \n was, so the
  -- cursor can be positioned there.

  lines' :: [(Char,a)] -> [[(Char,a)]]
  lines' [] =  []
  lines' s  = case s' of
                []          -> [l]
                ((_,x):s'') -> (l++[(' ',x)]) : lines' s''
              where
              (l, s') = break ((== '\n') . fst) s

  wrapLine :: Int -> [x] -> [[x]]
  wrapLine _ [] = []
  wrapLine n l = let (x,rest) = splitAt n l in x : wrapLine n rest
                                      
  expandGraphic ('\t', p) = replicate tabWidth (' ', p)
  expandGraphic (c,p) 
    | ord c < 32 = [('^',p),(chr (ord c + 64),p)]
    | otherwise = [(c,p)]

withStyle :: Style -> String -> Image
withStyle sty str = renderBS (attributesToAttr (appStyle sty) attr) (B.pack str)


------------------------------------------------------------------------

userForceRefresh :: UI -> IO ()
userForceRefresh = Vty.refresh . vty

-- | Schedule a refresh of the UI.
scheduleRefresh :: UI -> Editor -> IO ()
scheduleRefresh ui e = do
  writeRef (uiEditor ui) e
  logPutStrLn "scheduleRefresh"
  tryPutMVar (uiRefresh ui) ()
  return ()
-- The non-blocking behviour was set up with this in mind: if the display
-- thread is not able to catch up with the editor updates (possible since
-- display is much more time consuming than simple editor operations),
-- then there will be fewer display refreshes. 

-- | Calculate window heights, given all the windows and current height.
-- (No specific code for modelines)
computeHeights :: Int -> WindowSet Window  -> WindowSet Window
computeHeights totalHeight ws = result
  where (mwls, wls) = partition isMini (toList ws)
        (y,r) = getY (totalHeight - length mwls) (length wls) 
        (result, _) = runState (Data.Traversable.mapM distribute ws) ((y+r-1) : repeat y)

distribute :: Window -> State [Int] Window
distribute win = case isMini win of
                 True -> return win {height = 1}
                 False -> do h <- gets head
                             modify tail
                             return win {height = h}

getY :: Int -> Int -> (Int,Int)
getY screenHeight 0               = (screenHeight, 0)
getY screenHeight numberOfWindows = screenHeight `quotRem` numberOfWindows

------------------------------
-- Low-level stuff

------------------------------------------------------------------------

--
-- Combine attribute with another attribute
--
boldA, reverseA, nullA :: Vty.Attr -> Vty.Attr
boldA       = setBold
reverseA    = setRV
nullA       = id

------------------------------------------------------------------------

-- | Convert a Yi Attr into a Vty attribute change.
colorToAttr :: (Vty.Attr -> Vty.Attr) -> (Vty.Color -> Vty.Attr -> Vty.Attr) -> Vty.Color -> Style.Color -> (Vty.Attr -> Vty.Attr)
colorToAttr bold set unknown c =
  case c of 
    RGB 0 0 0         -> nullA    . set Vty.black
    RGB 128 128 128   -> bold     . set Vty.black
    RGB 139 0 0       -> nullA    . set Vty.red
    RGB 255 0 0       -> bold     . set Vty.red
    RGB 0 100 0       -> nullA    . set Vty.green
    RGB 0 128 0       -> bold     . set Vty.green
    RGB 165 42 42     -> nullA    . set Vty.yellow
    RGB 255 255 0     -> bold     . set Vty.yellow
    RGB 0 0 139       -> nullA    . set Vty.blue
    RGB 0 0 255       -> bold     . set Vty.blue
    RGB 128 0 128     -> nullA    . set Vty.magenta
    RGB 255 0 255     -> bold     . set Vty.magenta
    RGB 0 139 139     -> nullA    . set Vty.cyan
    RGB 0 255 255     -> bold     . set Vty.cyan
    RGB 165 165 165   -> nullA    . set Vty.white
    RGB 255 255 255   -> bold     . set Vty.white
    Default           -> nullA    . set Vty.def
    Reverse           -> reverseA . set Vty.def
    _                 -> nullA    . set unknown -- NB

attributesToAttr :: Attributes -> (Vty.Attr -> Vty.Attr)
attributesToAttr (Attributes fg bg) =
  colorToAttr boldA setFG Vty.black fg .
  colorToAttr nullA setBG Vty.white bg


---------------------------------


-- | Return @n@ elems starting at @i@ of the buffer as a list.
-- This routine also does syntax highlighting and applies overlays.
paintChars :: a -> [(Point,a)] -> [(Point,Char)] -> [(Char, (a,Point))]
paintChars sty [] cs = setSty sty cs
paintChars sty ((endPos,sty'):xs) cs = setSty sty left ++ paintChars sty' xs right
        where (left, right) = break ((endPos <=) . fst) cs

setSty :: a -> [(Point,Char)] -> [(Char, (a,Point))]
setSty sty cs = [(c,(sty,p)) | (p,c) <- cs]

toVtyStroke :: UIStyle -> Stroke -> (Point, Style, Point)
toVtyStroke sty (l,s,r) = (l,s sty,r)

