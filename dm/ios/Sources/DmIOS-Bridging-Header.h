// The C and Objective-C functions Launcher.swift, GameMenu.swift, LauncherSettings.swift and DmHostingController.swift call (CloudSaves.h, DmGameMenu.h, DmRotation.h, save_sync.h's report before Play, mods_api.h's mods, mic_level.h, the screen's rate). project.yml points SWIFT_OBJC_BRIDGING_HEADER here.
#import "CloudSaves.h"
#import "DmGameMenu.h"
#import "DmRotation.h"
#include "save_sync.h"
#include "mods_api.h"   // Mods.swift: the per-mod check and the import (hle_mods.c)
int front_screen_max_fps(void);   // front.h, front_ios.m: the Frame rate row offers 40 and 120 only on a 120 Hz screen (LauncherSettings.swift offeredOptions)
#include "mic_level.h"   // MicTester.swift: the voice leveler the capture runs (mic_apple.m), at the Mic Sensitivity slider
