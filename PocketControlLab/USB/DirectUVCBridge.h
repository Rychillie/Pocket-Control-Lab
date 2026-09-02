#ifndef DirectUVCBridge_h
#define DirectUVCBridge_h

#include <stdint.h>

typedef struct PocketUVCSession PocketUVCSession;

enum PocketUVCBridgeStage {
    PocketUVCBridgeStageNone = 0,
    PocketUVCBridgeStageDeviceLookup = 1,
    PocketUVCBridgeStagePluginCreation = 2,
    PocketUVCBridgeStageInterfaceQuery = 3,
    PocketUVCBridgeStageRequestValidation = 4,
    PocketUVCBridgeStageControlRequest = 5,
};

// Creates a legacy IOUSBLib user client without opening, seizing, resetting,
// configuring, or otherwise taking ownership of the USB device. It is expected
// to fail while macOS's UVC driver owns the camera; callers must fail closed.
PocketUVCSession *PocketUVCSessionCreate(
    uint32_t locationID,
    uint64_t registryID,
    int32_t *outStatus,
    uint32_t *outStage
);

void PocketUVCSessionDestroy(PocketUVCSession *session);

// Strictly whitelisted UVC class-interface requests only:
// - Camera Terminal 1: Zoom Absolute, Pan/Tilt Absolute, Roll Absolute
// - DJI Extension Unit 6: GET_INFO, GET_LEN, GET_CUR for selectors 1...3
//
// No API to send a vendor request, unknown selector, reset, configuration
// change, device open, or extension-unit write exists in this bridge.
int32_t PocketUVCSessionPerform(
    PocketUVCSession *session,
    uint8_t request,
    uint8_t selector,
    uint8_t entityID,
    uint8_t interfaceNumber,
    uint8_t *bytes,
    uint16_t length,
    uint32_t *outBytesTransferred,
    uint32_t *outStage
);

#endif
