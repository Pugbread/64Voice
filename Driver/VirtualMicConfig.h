// Build configuration for the 64Voice Mic driver, force-included before BlackHole.c
// (clang -include). Every constant here is one of BlackHole's documented build switches.
//
// The driver publishes two devices that share one loopback buffer:
//   "64Voice Mic"       visible, input only. Discord (or any app) records from it.
//   "64Voice Mic Feed"  hidden, output only. 64Voice plays the pinned mic into it and writes
//                       silence while dictating (see VirtualMicBridge.swift).
//
// The UIDs are part of the contract with VirtualMicBridge.swift. Change both together.

#define kDriver_Name                "64VoiceMic"
#define kHas_Driver_Name_Format     false   // UIDs: 64VoiceMic_UID, 64VoiceMic_2_UID
#define kPlugIn_BundleID            "com.pug64.64voice.mic"
#define kPlugIn_Icon                "64VoiceMic.icns"
#define kManufacturer_Name          "64Voice"

#define kDevice_Name                "64Voice Mic"
#define kDevice_IsHidden            false
#define kDevice_HasInput            true
#define kDevice_HasOutput           false

#define kDevice2_Name               "64Voice Mic Feed"
#define kDevice2_IsHidden           true
#define kDevice2_HasInput           false
#define kDevice2_HasOutput          true

// Stereo like stock BlackHole (the tested configuration); the bridge writes the mono mic to both.
#define kNumber_Of_Channels         2
// It's a mic. Never offer it as the system alert/sound-effects output.
#define kCanBeDefaultSystemDevice   false
