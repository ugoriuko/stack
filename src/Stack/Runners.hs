{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Utilities for running stack commands.
module Stack.Runners
    ( withBuildConfig
    , withEnvConfig
    , withDefaultEnvConfig
    , withConfig
    , withNoProject
    , withRunnerGlobal
    ) where

import           Stack.Prelude
import           RIO.Process (mkDefaultProcessContext)
import           Stack.Build.Target(NeedTargets(..))
import           Stack.Config
import           Stack.Constants
import           Stack.DefaultColorWhen (defaultColorWhen)
import qualified Stack.Docker as Docker
import qualified Stack.Nix as Nix
import           Stack.Setup
import           Stack.Types.Config
import           System.Console.ANSI (hSupportsANSIWithoutEmulation)
import           System.Terminal (getTerminalWidth)

-- | Ensure that no project settings are used when running 'withConfig'.
withNoProject :: RIO Runner a -> RIO Runner a
withNoProject = local (set stackYamlLocL SYLNoProject) -- FIXME consider adding a warning when overriding, or using SYLNoConfig

-- | Helper for 'withEnvConfig' which passes in some default arguments:
--
-- * No targets are requested
--
-- * Default command line build options are assumed
withDefaultEnvConfig
    :: RIO EnvConfig a
    -> RIO Config a
withDefaultEnvConfig = withEnvConfig AllowNoTargets defaultBuildOptsCLI

-- | Upgrade a 'Config' environment to a 'BuildConfig' environment by
-- performing further parsing of project-specific configuration. This
-- is intended to be run inside a call to 'withConfig'.
withBuildConfig :: RIO BuildConfig a -> RIO Config a
withBuildConfig inner = do
  bconfig <- loadBuildConfig
  runRIO bconfig inner

withEnvConfig
    :: NeedTargets
    -> BuildOptsCLI
    -> RIO EnvConfig a
    -- ^ Action that uses the build config.  If Docker is enabled for builds,
    -- this will be run in a Docker container.
    -> RIO Config a
withEnvConfig needTargets boptsCLI inner =
  Docker.reexecWithOptionalContainer $
  Nix.reexecWithOptionalShell $ withBuildConfig $ do
    envConfig <- setupEnv needTargets boptsCLI Nothing
    logDebug "Starting to execute command inside EnvConfig"
    runRIO envConfig inner

-- | Load the configuration. Convenience function used
-- throughout this module.
withConfig
  :: RIO Config a
  -> RIO Runner a
withConfig inner =
    loadConfig $ \config -> do
      -- If we have been relaunched in a Docker container, perform in-container initialization
      -- (switch UID, etc.).  We do this after first loading the configuration since it must
      -- happen ASAP but needs a configuration.
      view (globalOptsL.to globalDockerEntrypoint) >>=
        traverse_ (Docker.entrypoint config)
      runRIO config inner

withRunnerGlobal :: GlobalOpts -> RIO Runner a -> IO a
withRunnerGlobal go inner = do
  colorWhen <-
    case getFirst $ configMonoidColorWhen $ globalConfigMonoid go of
      Nothing -> defaultColorWhen
      Just colorWhen -> pure colorWhen
  useColor <- case colorWhen of
    ColorNever -> return False
    ColorAlways -> return True
    ColorAuto -> fromMaybe True <$>
                          hSupportsANSIWithoutEmulation stderr
  termWidth <- clipWidth <$> maybe (fromMaybe defaultTerminalWidth
                                    <$> getTerminalWidth)
                                   pure (globalTermWidth go)
  menv <- mkDefaultProcessContext
  logOptions0 <- logOptionsHandle stderr False
  let logOptions
        = setLogUseColor useColor
        $ setLogUseTime (globalTimeInLog go)
        $ setLogMinLevel (globalLogLevel go)
        $ setLogVerboseFormat (globalLogLevel go <= LevelDebug)
        $ setLogTerminal (globalTerminal go)
          logOptions0
  withLogFunc logOptions $ \logFunc -> runRIO Runner
    { runnerGlobalOpts = go
    , runnerUseColor = useColor
    , runnerLogFunc = logFunc
    , runnerTermWidth = termWidth
    , runnerProcessContext = menv
    } inner
  where clipWidth w
          | w < minTerminalWidth = minTerminalWidth
          | w > maxTerminalWidth = maxTerminalWidth
          | otherwise = w
