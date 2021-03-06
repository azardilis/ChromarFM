{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module AnalysisEvents where

import Types
import Control.Applicative
import Control.Monad
import Control.Lens hiding (at, (.>), (|>), elements, assign)
import qualified Data.ByteString.Lazy as BL
import Data.Colour
import Data.Colour.Names
import Data.Csv
import Data.Default.Class
import Data.Fixed
import Data.List
import qualified Data.Map as M
import qualified Data.Vector as V
import Graphics.Rendering.Chart
import Graphics.Rendering.Chart.Grid
import Graphics.Rendering.Chart.Backend.Cairo
import System.Environment
import Chromar.Fluent
import Data.Maybe
import Data.List.Split
import GHC.Exts
import System.FilePath.Posix
import Data.Clustering.Hierarchical
import GHC.Generics (Generic)
import qualified Math.KMeans as K
import qualified Data.Vector.Unboxed as UV

{- sometimes it's nicer to use these operators when doing data transformations
as it looks more natural to write M.map (sortWith timeE .> dropYrsE 15 .> getLifecycels)
and write the operations in the order that they happen (from left to right)
-}

infixl 9 .>
(.>) :: (a -> b) -> (b -> c) -> (a -> c)
f .> g = compose f g

(|>) :: a -> (a -> b) -> b
x |> f = apply x f

apply :: a -> (a -> b) -> b
apply x f = f x

compose :: (a -> b) -> (b -> c) -> (a -> c)
compose f g = \ x -> g (f x)

data Env = Env
    { te :: Int
    , year :: Int
    , photo :: Double
    , day :: Double
    , temp :: Double
    , moist :: Double
    } deriving (Generic, Show)

instance FromRecord Env

instance ToRecord Env

avgEnv :: [Env] -> Env
avgEnv envs = Env { te = te (head envs),
                    temp = avg (map temp envs),
                    moist = avg (map moist envs),
                    photo = avg (map photo envs),
                    day= 1,
                    year=2002}

readWeather :: FilePath -> IO ([Env])
readWeather fin = do
  csvData <- BL.readFile fin
  case decode NoHeader csvData of
    Left err -> error err
    Right v -> return $ V.toList v

writeWeather :: FilePath -> [Env] -> IO ()
writeWeather fout envs = BL.writeFile fout (encode envs)

data Location
    = Norwich
    | Halle
    | Valencia
    | Oulu
    deriving (Show)

codeName :: Location -> String
codeName Norwich = "Nor"
codeName Halle = "Hal"
codeName Oulu = "Oul"
codeName Valencia = "Val"

isNSSet Event{typeE=Flower} = True
isNSSet Event{typeE=Germ} = True
isNSSet _ = False

{-
  we should add a phantom type to keep track of the
  unit for time + type parameter for time
-}
data Lifecycle = Lifecycle
    { pidL :: Int
    , pssetT :: Double
    , germT :: Double
    , flowerT :: Double
    , ssetT :: Double
    } deriving Show

toWeek :: Lifecycle -> Lifecycle
toWeek Lifecycle {pidL = p
                 ,pssetT = pst
                 ,germT = gt
                 ,flowerT = ft
                 ,ssetT = st} =
    Lifecycle
    { pidL = p
    , pssetT = fromIntegral $ truncate (pst / 7)
    , germT = fromIntegral $ truncate (gt / 7)
    , flowerT = fromIntegral $ truncate (ft / 7)
    , ssetT = fromIntegral $ truncate (st / 7)
    }

eqTiming :: Lifecycle -> Lifecycle -> Bool
eqTiming Lifecycle {germT = gt
                   ,pssetT = pst
                   ,flowerT = ft
                   ,ssetT = st} Lifecycle {pssetT = pst'
                                          ,germT = gt'
                                          ,flowerT = ft'
                                          ,ssetT = st'} =
    (gt == gt') && (ft == ft') && (st == st') && (pst == pst')

compCounts :: (a, Int) -> (a, Int) -> Ordering
compCounts (_, n) (_, m)
  | n > m = GT
  | n == m = EQ
  | n < m = LT

compLfs :: Lifecycle -> Lifecycle -> Double
compLfs Lifecycle {germT = gt
                 ,flowerT = ft
                 ,ssetT = st} Lifecycle {germT = gt'
                                        ,flowerT = ft'
                                        ,ssetT = st'} =
    abs (gt - gt') + abs (ft - ft') + abs (st - st')

compLfs' :: Lifecycle -> Lifecycle -> Double
compLfs' Lifecycle {
                   pssetT =pst
                 , germT = gt
                 ,flowerT = ft
                 ,ssetT = st} Lifecycle {pssetT = pst',
                                         germT = gt'
                                        ,flowerT = ft'
                                        ,ssetT = st'} =
  abs (lenLf1 - lenLf2)
  where
    lenLf1 = st - pst
    lenLf2 = st' - pst'

clusterLfs lfs = dendrogram SingleLinkage lfs compLfs

clusterLfs' lfs = dendrogram SingleLinkage lfs compLfs'

clusterLfsK k lfs = map K.elements clusters
  where
    clusters =
        (V.toList (K.kmeans (\lf -> UV.singleton (getLen lf)) K.euclidSq k lfs)) :: [K.Cluster Lifecycle]

clusterLfsK' k lfs = map K.elements clusters
  where
    clusters =
        V.toList (K.kmeans (\lf -> UV.fromList [germD lf, vegSLenD lf]) K.euclidSq k lfs) :: [K.Cluster Lifecycle]
                                                                                             
getAtLevel :: Int -> Dendrogram a -> [[a]]
getAtLevel n (Leaf k) = [[k]]
getAtLevel 0 d = [elements d]
getAtLevel n (Branch _ d1 d2) = getAtLevel (n-1) d1 ++ getAtLevel (n-1) d2

getD :: Dendrogram a -> Double
getD (Leaf k) = 0.0
getD (Branch d _ _) = d

flookupMDef ::
    a -> M.Map Time a -> Fluent a
flookupMDef def tvals =
    mkFluent (\t -> fromMaybe def $ fmap snd (M.lookupLE t tvals))

type TSeries a = [(Time, a)]

mkHist :: (RealFrac a) => Colour Double -> [a] -> Plot a Int
mkHist c vals =
    histToPlot
        (  plot_hist_fill_style . fill_color .~ (c `withOpacity` 0.1) $
           plot_hist_values .~ vals $ def)

{- plots histograms on top of each other -}
plotHists fout xtitle plots = renderableToFile foptions fout chart
  where
    layout = layout_plots .~ plots
           $ layout_x_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_y_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_x_axis . laxis_title_style . font_size .~ 20.0
           $ layout_x_axis . laxis_title .~ xtitle
           $ layout_y_axis . laxis_title_style . font_size .~ 20.0
           $ layout_y_axis . laxis_title .~ "counts"
           $ layout_legend .~ Just (legend_label_style . font_size .~ 16.0 $ def)
           $ def

    chart = toRenderable layout

    foptions = fo_size .~ (500,200) $ def

mkHist' :: [Colour Double] -> String -> String -> [[Double]] -> Layout Double Int
mkHist' cs xtitle title valss = layout
  where
    plot c vals =
        histToPlot
            (plot_hist_fill_style . fill_color .~ (c `withOpacity` 0.1) $
             plot_hist_values .~ vals $
             def :: PlotHist Double Int)
    layout = layout_plots .~ [plot c vals | (c, vals) <- zip cs valss]
           $ layout_title  .~ title
           $ layout_x_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_y_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_x_axis . laxis_title_style . font_size .~ 20.0
           $ layout_x_axis . laxis_title .~ xtitle
           $ layout_y_axis . laxis_title_style . font_size .~ 20.0
           $ layout_y_axis . laxis_title .~ "counts"
           $ layout_legend .~ Just (legend_label_style . font_size .~ 16.0 $ def)
           $ def

mkPoints' :: [Colour Double] -> String -> String -> [[(Double, Double)]] -> Layout Double Double
mkPoints' cs xtitle ytitle valss = layout
  where
    plot c vals = toPlot (plot_points_style .~ filledCircles 1 (c `withOpacity` 0.6)
              $ plot_points_values .~ vals
              $ def )   
    layout = layout_plots .~ [plot c vals | (c, vals) <- zip cs valss]
           $ layout_title  .~ ""
           $ layout_x_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_y_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_x_axis . laxis_title_style . font_size .~ 20.0
           $ layout_x_axis . laxis_title .~ xtitle
           $ layout_y_axis . laxis_title_style . font_size .~ 20.0
           $ layout_y_axis . laxis_title .~ ytitle
           $ layout_legend .~ Just (legend_label_style . font_size .~ 16.0 $ def)
           $ def

mkLine' :: [Colour Double] -> String -> String -> [[(Double, Double)]] -> Layout Double Double
mkLine' cs ytitle xtitle tvalss = layout
  where
    plot c tvals =
        toPlot
            (  plot_lines_values .~ [tvals]
             $ plot_lines_style . line_color .~ (c `withOpacity` 0.9)
             $ plot_lines_style . line_width .~ 2.0
             $ def)
    layout = layout_plots .~ [plot c vals | (c, vals) <- zip cs tvalss]
           $ layout_title  .~ ""
           $ layout_x_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_y_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_x_axis . laxis_title_style . font_size .~ 20.0
           $ layout_x_axis . laxis_title .~ xtitle
           $ layout_y_axis . laxis_title_style . font_size .~ 20.0
           $ layout_y_axis . laxis_title .~ ytitle
           $ layout_legend .~ Just (legend_label_style . font_size .~ 16.0 $ def)
           $ def

{- plots histograms arranged on a grid -}
plotHistsGrid fout x hists = renderableToFile foptions fout $ fillBackground def $ chart
  where
    histsG = map layoutToGrid hists
    fullGrid = aboveN (map besideN (chunksOf x histsG))

    chart = gridToRenderable fullGrid

    foptions = fo_size .~ (900,500) $ def

{- plots histograms arranged on a grid -}
plotHistsGridR x hists = fillBackground def $ chart
  where
    histsG = map layoutToGrid hists
    fullGrid = aboveN (map besideN (chunksOf x histsG))

    chart = gridToRenderable fullGrid

getDayYear :: Double -> Double
getDayYear time = fromIntegral dayYear
  where
    hourYear = mod' time (365*24)
    dayYear = truncate (hourYear / 24.0)

avg l =
    let (t, n) = foldl' (\(b, c) a -> (a + b, c + 1)) (0, 0) l
    in (realToFrac t / realToFrac n)

median l = sort l !! (length l `quot` 2)

dropYrs :: Int -> TSeries Int -> TSeries Int
dropYrs n ts = dropWhile (\(t, _) -> t < yrHours) ts
  where
    yrHours = fromIntegral (n * 365*24)

dropYrsE :: Int -> [Event] -> [Event]
dropYrsE n es = dropWhile isNSSet (dropWhile (\e -> timeE e < yrHours) es)
  where
    yrHours = fromIntegral (n * 365*24)

extractTSeries :: (Event -> a) -> [Time] -> [Event] -> TSeries a
extractTSeries ext tss ps = [(t, at f t) | t <- tss]
  where
    n = ext $ head ps
    f = flookupMDef n (M.fromList [(timeE p, ext p) | p <- ps])

avgYear :: TSeries Int -> TSeries Double
avgYear ts = M.toList avgy
  where
    toYear ts =
        [ (getDayYear h, fromIntegral el)
        | (h, el) <- ts ]
    toN ts =
        [ (d, 1)
        | (d, el) <- ts ]
    m = M.fromListWith (+) (toYear ts)
    n = M.fromListWith (+) (toN . toYear $ ts)
    avgy = M.unionWith (/) m n

{-
Write multiple timeseries assuming that their time indexes are the same
precondition is not checked
-}
writeOut fout nms (ts1, ts2, ts3) = writeFile fout (unlines rows)
  where
    catc t v1 v2 v3 = intercalate "," (map show [t, v1, v2, v3])
    header = "time" ++ "," ++ intercalate "," nms
    rows =
        header :
        [ catc t v1 v2 v3
        | ((t, v1), (_, v2), (_, v3)) <- zip3 ts1 ts2 ts3 ]

goAvgYearWrite fout ps =
    writeOut fout ["nseeds", "nplants", "nfplants"] (tseeds, tplants, tfplants)
  where
    tss = [0,24 .. 60 * 365 * 24]
    tseeds = avgYear (dropYrs 15 . extractTSeries nSeeds tss $ ps)
    tplants = avgYear (dropYrs 15 . extractTSeries nPlants tss $ ps)
    tfplants = avgYear (dropYrs 15 . extractTSeries nFPlants tss $ ps)

mkLifecycle :: [Event] -> [Event] -> Maybe Lifecycle
mkLifecycle [Event{timeE=t, pid=i, typeE=SeedSet},
             Event{timeE=t1, typeE=Germ},
             Event{timeE=t2, typeE=Flower}] (Event{timeE=t3, typeE=SeedSet}:ess2) =
  Just Lifecycle {pidL =i, pssetT=t, germT=t1, flowerT=t2, ssetT=t3}
mkLifecycle _ _ = Nothing

collectLFs :: [[Event]] -> [Maybe Lifecycle]
collectLFs [] = []
collectLFs [es] = []
collectLFs (es1:es2:ess) = mkLifecycle es1 es2 : collectLFs (es2:ess)

getLfs :: [Event] -> [Lifecycle]
getLfs es = catMaybes (collectLFs (chunksOf 3 es))

groupById :: [Event] -> M.Map Int [Event]
groupById es =
    M.fromListWith
        (++)
        [ (pid e, [e])
        | e <- es ]

groupByIdL :: [Lifecycle] -> M.Map Int [Lifecycle]
groupByIdL ls =
   M.fromListWith (++) [(pidL lf, [lf]) | lf <- ls]

hourToDay :: Int -> Int
hourToDay h = truncate (fromIntegral h / 24.0)

groupByDay :: ([Env] -> Env) -> [Env] -> [Env]
groupByDay f es = sortWith te (M.elems esByDay)
  where
    esByDay =
        (M.map
             (sortWith te .> f)
             (M.fromListWith
                  (++)
                  [ (hourToDay (te e), [e])
                  | e <- es ]))

getLfDistr :: [Event] -> [Lifecycle]
getLfDistr es =
    M.foldr (++) [] (M.map (sortWith timeE .> dropYrsE 15 .> getLfs) es')
  where
    es' = groupById es

getLen :: Lifecycle -> Double
getLen lf = ssetT lf - pssetT lf

getLens :: [Lifecycle] -> [Double]
getLens ls = map getLen ls

writeLens :: FilePath -> [Double] -> IO ()
writeLens fout ls = writeFile fout (unlines $ map show ls)

sortLFs :: Double -> Double -> [Lifecycle] -> ([Lifecycle], [Lifecycle])
sortLFs t1 t2 ls = (livesF cond1, livesF cond2)
  where
    cond1 t1 t2 = abs t1 < abs t2
    cond2 t1 t2 = abs t1 >= abs t2
    livesF cond =
        [ life
        | life <- ls
        , let len = ssetT life - pssetT life
        , let ct1 = len - t1
        , let ct2 = len - t2
        , cond ct1 ct2 ]

getPsis :: [Double] -> M.Map Int Double
getPsis psis =
    M.fromList
        [ (i, p)
        | (i, p) <- zip [1 .. length psis] psis ]

multIndex :: [Int] -> M.Map Int a -> [a]
multIndex is m = [m M.! i | i <- is]

readEvents :: FilePath -> IO [Event]
readEvents fin = do
  csvData <- BL.readFile fin
  case decodeByName csvData of
    Left err -> error err
    Right (_, v) -> return $ V.toList v

readPsis :: FilePath -> IO (M.Map Int Double)
readPsis fin = do
  psisS <- readFile fin
  return $ getPsis (map read (lines psisS))

showEnv' (p, f) = "d" ++ show p ++ "_" ++ "r" ++ show f

mkFNamePsis bfout loc e =
    bfout ++ codeName loc ++ "/outEvents_psis" ++ showEnv' e ++ ".txt"

mkFName bfout loc e =
    bfout ++ codeName loc ++ "/outEventsH" ++ "_" ++ showEnv' e ++ ".txt"

mkFOut bfout loc e =
    bfout ++
    codeName loc ++ "/outEvents" ++ "_" ++ showEnv' e ++ "AvgYear.txt"

mkFOutPlot bfout loc e nm =
    bfout ++ codeName loc ++ "/plots/" ++ nm ++ showEnv' e ++ ".png"

doTimings :: FilePath -> IO ()
doTimings bfout = mapM_ doTiming fnames
  where
    locs = [Norwich, Halle, Oulu, Valencia]
    envs =
        [ (p, f)
        | p <- [0.0, 2.5]
        , f <- [0.598, 0.737] ]
    fnames =
        [ (mkFName bfout loc (p, f), mkFOut bfout loc (p, f))
        | loc <- locs
        , (p, f) <- envs ]
    doTiming (fin, fout) = readEvents fin >>= (\es -> goAvgYearWrite fout es)

doLengthsHist (fin, fout) = do
  lives <- fmap getLfDistr (readEvents fin)
  let lens = map (/24) (getLens lives)
  plotHists fout "days" [mkHist blue lens]

doNLivesHist (fin, fout) = do
  es <- fmap groupById (readEvents fin)
  let lives = M.map
              (fromIntegral . length . getLfs . dropYrsE 15 . sortWith timeE)
              es :: M.Map Int Double
  plotHists fout "# of lifecycles (45 years)" [mkHist red (M.elems lives)]

{- do histogram for lifecycle lengths
   and # of lifecycles per location per genotype
-}
doHistograms :: FilePath -> IO ()
doHistograms bfout = do
    mapM_ doLengthsHist fnames
    mapM_ doNLivesHist fnames'
  where
    locs = [Norwich, Halle, Oulu, Valencia]
    envs =
        [ (p, f)
        | p <- [0.0, 2.5]
        , f <- [0.598, 0.737] ]
    fnames =
        [ (mkFName bfout loc (p, f), mkFOutPlot bfout loc (p, f) "lengths")
        | loc <- locs
        , (p, f) <- envs ]
    fnames' =
        [ (mkFName bfout loc (p, f), mkFOutPlot bfout loc (p, f) "nLives")
        | loc <- locs
        , (p, f) <- envs ]

vegSLen :: Lifecycle -> Time
vegSLen lf = flowerT lf - germT lf

vegSLens = map vegSLen

reprSLen :: Lifecycle -> Time
reprSLen lf = ssetT lf - flowerT lf

reprSLens = map reprSLen

dormSLen lf = germT lf - pssetT lf

dormSLens = map dormSLen

vegF :: FilePath -> IO ()
vegF fp = do
    print fp
    lives <- fmap getLfDistr (readEvents fp)
    print $ avg (map (getDayYear . germT) lives)
    print $ (avg $ vegSLens lives) / 24

reprF :: FilePath -> IO ()
reprF fp = do
    print fp
    lives <- fmap getLfDistr (readEvents fp)
    print $ avg (map (getDayYear . flowerT) lives)
    print $ (avg $ reprSLens lives) / 24

doFiles :: FilePath -> (FilePath -> IO ()) -> IO ()
doFiles bfout f = mapM_ f fnames
  where
    locs = [Valencia, Oulu, Halle, Norwich]
    envs = [(p, f) | p <- [0.0, 2.5], f <- [0.598, 0.737]]
    fnames = [mkFName bfout loc (p, f) | loc <- locs, (p, f) <- envs]

doPsis :: FilePath -> IO ()
doPsis bfout = mapM_ plotPsis fnames
  where
    locs = [Valencia, Oulu, Halle, Norwich]
    envs =
        [ (p, f)
        | p <- [0.0, 2.5]
        , f <- [0.598, 0.737] ]
    fnames =
        [ (mkFNamePsis bfout loc (p, f), mkFOutPlot bfout loc (p, f) "psisH")
        | loc <- locs
        , (p, f) <- envs ]
    plotPsis (fin, fout) =
        readPsis fin >>=
        (\mpsi -> plotHists fout "psi" [mkHist green (M.elems mpsi)])

data Pair a = P a a

instance Functor Pair where
  fmap f (P x y) = P (f x) (f y)
  
inl :: Pair a -> a
inl (P x _) = x

inr :: Pair a -> a
inr (P _ y) = y

zipF :: (a -> b) -> (a -> c) -> a -> (b, c)
zipF f1 f2 v = (f1 v, f2 v)

germD = germT .> getDayYear
flowerD = flowerT .> getDayYear
ssetD = ssetT .> getDayYear

germDs = map germD
flowerDs = map flowerD
ssetDs = map ssetD

vegSLenD = vegSLen .> (/24)

getLensD = map (getLen .> (/24))
vegSLensD = map (vegSLen .> (/24))
reprSLensD = map (reprSLen .> (/24))
dormSLensD = map (dormSLen .> (/24))

ratio :: Int -> Int -> Double
ratio k m = fromIntegral k / fromIntegral (k + m )

ratioN :: [Int] -> [Double]
ratioN xs = map (/ (sum fxs)) fxs
   where
     fxs = map fromIntegral xs

getTotalMass :: Int -> [(Double, Double)] -> Double
getTotalMass n pms = sum [p*(fromIntegral n)*m | (p, m) <- pms]

--- biomass game with more than 1 seed
data Cluster = Cluster
    { cid :: Int
    , bmass :: Double
    , len :: Double
    , cgermD :: Double
    , cvegLen :: Double
    } deriving (Show)

type Mass = Double

assign :: [Cluster] -> Lifecycle -> Cluster
assign cs lf =
    head .> fst $
    sortWith
        snd
        [ (c, dist lf c)
        | c <- cs ]
  where
    dist lf c = euclDist (extract c) (extractL lf)

breadthW :: Mass -> Double
breadthW m
    | m < 0.2 = 0.0
    | otherwise = 1.0
    
logistic :: (Double, Double) -> Double -> Double
logistic (k, x0) x = 1.0 / (1 + exp (-k*(x - x0)))

getMassLineage :: [Cluster] -> (Mass -> Double) -> [Lifecycle] -> Mass
getMassLineage cs f lfs = sum (zipWith (*) mss bss)
  where
    mss = map (assign cs .> bmass) lfs
    bss = scanl (*) 1.0 (map f mss)

getLineage :: [Cluster] -> [Lifecycle] -> [Lifecycle]
getLineage cs lfs = map fst (takeWhile (\(lf, b) -> b > 0.0) (zip lfs bss))
  where
    mss = map (assign cs .> bmass .> breadthW) lfs
    bss = scanl (*) 1.0 mss
    
lineages ess = M.map (sortWith timeE .> dropYrsE 15 .> getLfs) ess

euclDist :: [Double] -> [Double] -> Double
euclDist xs ys = sum $ zipWith (\x y -> (x - y) ** 2) xs ys

extract :: Cluster -> [Double]
extract c = [len c, cgermD c, cvegLen c]

extractL :: Lifecycle -> [Double]
extractL lf = [getLen .> (/ 24) $ lf, germD lf, vegSLenD lf]

vsumm :: Lifecycle -> IO ()
vsumm lf = do
   print "Lf length"
   print (getLen .> (/24) $ lf)
   print "Germ d"
   print (germD lf)
   print "Veg season length"
   print (vegSLenD lf)

mkHeatMap :: String -> String -> [(Double, Double, Double, Double)] -> Layout Double Double
mkHeatMap xtitle ytitle vals = layout 
  where
     plot = toPlot ( area_spots_4d_values .~ vals
                   $ area_spots_4d_max_radius .~ 8
                   $ def)
     layout = layout_plots .~ [plot]
           $ layout_title  .~ ""
           $ layout_x_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_y_axis . laxis_style . axis_label_style . font_size .~ 18.0
           $ layout_x_axis . laxis_title_style . font_size .~ 20.0
           $ layout_x_axis . laxis_title .~ xtitle
           $ layout_y_axis . laxis_title_style . font_size .~ 20.0
           $ layout_legend .~ Just (legend_label_style . font_size .~ 16.0 $ def)
           $ layout_y_axis . laxis_title .~ ytitle
           $ def


-- plotHistsGridR
--     1
--     [ mkPoints''
--           [blue]
--           "x"
--           "y"
--           "title"
--           [ [ ( fromIntegral (tep e)
--               , phRate (tempp e) (par e) (photop e) (moistp e))
--             | e <- wd ]
--           ]
--     ]
