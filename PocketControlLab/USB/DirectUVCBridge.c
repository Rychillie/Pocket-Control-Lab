// A repository-wide license must be selected before public distribution.
//
// Safe, deliberately narrow bridge for standard UVC class control transfers.
//
// Safety invariants:
// - never calls USBDeviceOpen, USBDeviceOpenSeize, USBInterfaceOpen, or seize;
// - never resets, reconfigures, claims an interface, uses endpoint I/O, or
//   sends a vendor-specific request;
// - permits SET_CUR only for the three explicitly allowed Camera Terminal
//   controls and provides no Extension Unit write path at all;
// - returns immediately if macOS refuses the normal legacy user client.

#include "DirectUVCBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdint.h>
#include <stdlib.h>

enum {
    kPocketVendorID = 0x2CA3,
    kPocketProductID = 0x0023,
    kVideoControlInterface = 0,
    kCameraTerminalID = 1,
    kDJIExtensionUnitID = 6,

    kUVCSetCurrent = 0x01,
    kUVCGetCurrent = 0x81,
    kUVCGetMinimum = 0x82,
    kUVCGetMaximum = 0x83,
    kUVCGetResolution = 0x84,
    kUVCGetLength = 0x85,
    kUVCGetInfo = 0x86,
    kUVCGetDefault = 0x87,

    kCTZoomAbsolute = 0x0B,
    kCTPanTiltAbsolute = 0x0D,
    kCTRollAbsolute = 0x0F,

    kUVCGetRequestType = 0xA1,
    kUVCSetRequestType = 0x21,
    kMaximumExtensionUnitReadLength = 1024,
    kRequestTimeoutMilliseconds = 1000,
};

struct PocketUVCSession {
    IOUSBDeviceInterface **device;
    uint32_t locationID;
    uint64_t registryID;
};

static void set_result(int32_t *outStatus, uint32_t *outStage, int32_t status, uint32_t stage) {
    if (outStatus != NULL) {
        *outStatus = status;
    }
    if (outStage != NULL) {
        *outStage = stage;
    }
}

static int registry_number_equals(io_registry_entry_t service, CFStringRef key, uint64_t expected) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        if (value != NULL) {
            CFRelease(value);
        }
        return 0;
    }

    int64_t number = 0;
    Boolean converted = CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number);
    CFRelease(value);
    return converted && number >= 0 && (uint64_t)number == expected;
}

static int registry_string_contains(
    io_registry_entry_t service,
    CFStringRef key,
    CFStringRef expectedSubstring
) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        if (value != NULL) {
            CFRelease(value);
        }
        return 0;
    }

    CFStringRef string = (CFStringRef)value;
    CFRange range = CFStringFind(
        string,
        expectedSubstring,
        kCFCompareCaseInsensitive | kCFCompareNonliteral
    );
    CFRelease(value);
    return range.location != kCFNotFound;
}

static int has_validated_pocket4_product_identity(io_registry_entry_t service) {
    // A Pocket 4 control session must not be selected by VID/PID alone. These
    // cached string properties are read from the IORegistry; no USB transfer
    // is made to obtain them.
    return registry_string_contains(service, CFSTR("USB Product Name"), CFSTR("OsmoPocket4"))
        || registry_string_contains(service, CFSTR("kUSBProductString"), CFSTR("OsmoPocket4"));
}

static io_service_t copy_matching_pocket_device(uint32_t locationID, uint64_t registryID) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL) {
        return IO_OBJECT_NULL;
    }

    int32_t vendor = kPocketVendorID;
    int32_t product = kPocketProductID;
    CFNumberRef vendorNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vendor);
    CFNumberRef productNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &product);
    if (vendorNumber == NULL || productNumber == NULL) {
        if (vendorNumber != NULL) {
            CFRelease(vendorNumber);
        }
        if (productNumber != NULL) {
            CFRelease(productNumber);
        }
        CFRelease(matching);
        return IO_OBJECT_NULL;
    }

    CFDictionarySetValue(matching, CFSTR("idVendor"), vendorNumber);
    CFDictionarySetValue(matching, CFSTR("idProduct"), productNumber);
    CFRelease(vendorNumber);
    CFRelease(productNumber);

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (result != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    io_service_t found = IO_OBJECT_NULL;
    io_service_t candidate = IO_OBJECT_NULL;
    while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint64_t candidateRegistryID = 0;
        if (registry_number_equals(candidate, CFSTR("locationID"), locationID)
            && IORegistryEntryGetRegistryEntryID(candidate, &candidateRegistryID) == KERN_SUCCESS
            && candidateRegistryID == registryID
            && has_validated_pocket4_product_identity(candidate)) {
            found = candidate;
            break;
        }
        IOObjectRelease(candidate);
    }

    IOObjectRelease(iterator);
    return found;
}

static int expected_camera_terminal_length(uint8_t selector) {
    switch (selector) {
        case kCTZoomAbsolute:
        case kCTRollAbsolute:
            return 2;
        case kCTPanTiltAbsolute:
            return 8;
        default:
            return 0;
    }
}

static int is_allowed_camera_terminal_request(uint8_t request, uint8_t selector, uint16_t length) {
    int expectedLength = expected_camera_terminal_length(selector);
    if (expectedLength == 0) {
        return 0;
    }

    switch (request) {
        case kUVCGetInfo:
            return length == 1;
        case kUVCGetCurrent:
        case kUVCGetMinimum:
        case kUVCGetMaximum:
        case kUVCGetResolution:
        case kUVCGetDefault:
        case kUVCSetCurrent:
            return length == (uint16_t)expectedLength;
        default:
            return 0;
    }
}

static int is_allowed_extension_unit_request(uint8_t request, uint8_t selector, uint16_t length) {
    if (selector < 1 || selector > 3) {
        return 0;
    }

    switch (request) {
        case kUVCGetInfo:
            return length == 1;
        case kUVCGetLength:
            return length == 2;
        case kUVCGetCurrent:
            return length > 0 && length <= kMaximumExtensionUnitReadLength;
        default:
            return 0;
    }
}

static int is_allowed_request(
    uint8_t request,
    uint8_t selector,
    uint8_t entityID,
    uint8_t interfaceNumber,
    uint16_t length
) {
    if (interfaceNumber != kVideoControlInterface) {
        return 0;
    }

    if (entityID == kCameraTerminalID) {
        return is_allowed_camera_terminal_request(request, selector, length);
    }

    if (entityID == kDJIExtensionUnitID) {
        return is_allowed_extension_unit_request(request, selector, length);
    }

    return 0;
}

PocketUVCSession *PocketUVCSessionCreate(
    uint32_t locationID,
    uint64_t registryID,
    int32_t *outStatus,
    uint32_t *outStage
) {
    set_result(outStatus, outStage, kIOReturnSuccess, PocketUVCBridgeStageNone);

    io_service_t service = copy_matching_pocket_device(locationID, registryID);
    if (service == IO_OBJECT_NULL) {
        set_result(outStatus, outStage, kIOReturnNotFound, PocketUVCBridgeStageDeviceLookup);
        return NULL;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t result = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    IOObjectRelease(service);

    if (result != kIOReturnSuccess || plugin == NULL) {
        set_result(outStatus, outStage, result, PocketUVCBridgeStagePluginCreation);
        return NULL;
    }

    IOUSBDeviceInterface **device = NULL;
    HRESULT queryResult = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
        (LPVOID)&device
    );
    IODestroyPlugInInterface(plugin);

    if (queryResult != S_OK || device == NULL) {
        set_result(outStatus, outStage, kIOReturnUnsupported, PocketUVCBridgeStageInterfaceQuery);
        return NULL;
    }

    PocketUVCSession *session = calloc(1, sizeof(PocketUVCSession));
    if (session == NULL) {
        (*device)->Release(device);
        set_result(outStatus, outStage, kIOReturnNoMemory, PocketUVCBridgeStageInterfaceQuery);
        return NULL;
    }

    session->device = device;
    session->locationID = locationID;
    session->registryID = registryID;
    return session;
}

void PocketUVCSessionDestroy(PocketUVCSession *session) {
    if (session == NULL) {
        return;
    }

    if (session->device != NULL) {
        (*session->device)->Release(session->device);
    }
    free(session);
}

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
) {
    if (outBytesTransferred != NULL) {
        *outBytesTransferred = 0;
    }
    if (outStage != NULL) {
        *outStage = PocketUVCBridgeStageNone;
    }

    if (session == NULL || session->device == NULL || bytes == NULL || length == 0) {
        if (outStage != NULL) {
            *outStage = PocketUVCBridgeStageRequestValidation;
        }
        return kIOReturnBadArgument;
    }

    if (!is_allowed_request(request, selector, entityID, interfaceNumber, length)) {
        if (outStage != NULL) {
            *outStage = PocketUVCBridgeStageRequestValidation;
        }
        return kIOReturnBadArgument;
    }

    // Re-check the cached IORegistry identity immediately before every
    // transfer. If the device was unplugged or another unit appeared at the
    // same port, an old session can never issue a request to the replacement.
    io_service_t currentService = copy_matching_pocket_device(
        session->locationID,
        session->registryID
    );
    if (currentService == IO_OBJECT_NULL) {
        if (outStage != NULL) {
            *outStage = PocketUVCBridgeStageDeviceLookup;
        }
        return kIOReturnNotAttached;
    }
    IOObjectRelease(currentService);

    const int isSetRequest = request == kUVCSetCurrent;
    IOUSBDevRequestTO controlRequest = {
        .bmRequestType = isSetRequest ? kUVCSetRequestType : kUVCGetRequestType,
        .bRequest = request,
        .wValue = (UInt16)selector << 8,
        .wIndex = ((UInt16)entityID << 8) | interfaceNumber,
        .wLength = length,
        .pData = bytes,
        .wLenDone = 0,
        .noDataTimeout = kRequestTimeoutMilliseconds,
        .completionTimeout = kRequestTimeoutMilliseconds,
    };

    IOReturn result = (*session->device)->DeviceRequestTO(session->device, &controlRequest);
    if (outBytesTransferred != NULL) {
        *outBytesTransferred = controlRequest.wLenDone;
    }
    if (outStage != NULL) {
        *outStage = PocketUVCBridgeStageControlRequest;
    }
    return result;
}
