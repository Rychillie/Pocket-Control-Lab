// A repository-wide license must be selected before public distribution.
//
// Read-only DJI Osmo Pocket 4 USB descriptor inspector.
//
// Safety invariant:
//   This program never calls USBDeviceOpen, USBDeviceOpenSeize, DeviceRequest,
//   SetConfiguration, ResetDevice, or any pipe/endpoint operation.  It only
//   reads IORegistry properties and the macOS-cached configuration descriptor
//   through IOUSBDeviceInterface::GetConfigurationDescriptorPtr().

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    kDJIVendorID = 0x2CA3,
    kPocket4ProductID = 0x0023,
    kUSBDescriptorTypeConfiguration = 0x02,
    kUSBDescriptorTypeInterface = 0x04,
    kUSBDescriptorTypeEndpoint = 0x05,
    kUSBDescriptorTypeInterfaceAssociation = 0x0B,
    kUSBDescriptorTypeClassSpecificInterface = 0x24,
    kUSBDescriptorTypeClassSpecificEndpoint = 0x25,
    kUSBClassVideo = 0x0E,
    kUSBVideoSubclassControl = 0x01,
    kUSBVideoSubclassStreaming = 0x02,
};

static int include_identifiers = 0;

static uint16_t read_le16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t read_le32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static void print_indent(unsigned level) {
    for (unsigned index = 0; index < level; ++index) {
        fputs("  ", stdout);
    }
}

static void print_hex(const uint8_t *bytes, size_t length, unsigned indent) {
    for (size_t offset = 0; offset < length; offset += 16) {
        print_indent(indent);
        printf("%04zx: ", offset);
        size_t lineLength = length - offset;
        if (lineLength > 16) {
            lineLength = 16;
        }
        for (size_t index = 0; index < lineLength; ++index) {
            printf("%02X ", bytes[offset + index]);
        }
        putchar('\n');
    }
}

static void print_bytes_inline(const uint8_t *bytes, size_t length) {
    for (size_t index = 0; index < length; ++index) {
        printf("%02X", bytes[index]);
        if (index + 1 < length) {
            putchar(' ');
        }
    }
}

static int bitmap_bit(const uint8_t *bitmap, size_t bytes, unsigned bit) {
    return bit / 8 < bytes && (bitmap[bit / 8] & (uint8_t)(1u << (bit % 8))) != 0;
}

static const char *usb_class_name(uint8_t value) {
    switch (value) {
        case 0x01: return "Audio";
        case 0x02: return "Communications/CDC";
        case 0x03: return "HID";
        case 0x08: return "Mass Storage";
        case 0x09: return "Hub";
        case 0x0A: return "CDC Data";
        case 0x0E: return "Video/UVC";
        case 0xEF: return "Miscellaneous/IAD composite";
        case 0xFF: return "Vendor-specific";
        default: return "Other/defined by interface";
    }
}

static const char *video_subclass_name(uint8_t value) {
    switch (value) {
        case kUSBVideoSubclassControl: return "Video Control";
        case kUSBVideoSubclassStreaming: return "Video Streaming";
        case 0x03: return "Video Interface Collection";
        default: return "Unknown video subclass";
    }
}

static const char *audio_subclass_name(uint8_t value) {
    switch (value) {
        case 0x01: return "Audio Control";
        case 0x02: return "Audio Streaming";
        case 0x03: return "MIDI Streaming";
        default: return "Unknown audio subclass";
    }
}

static const char *transfer_type_name(uint8_t attributes) {
    switch (attributes & 0x03) {
        case 0x00: return "Control";
        case 0x01: return "Isochronous";
        case 0x02: return "Bulk";
        case 0x03: return "Interrupt";
        default: return "Unknown";
    }
}

static const char *vc_subtype_name(uint8_t value) {
    switch (value) {
        case 0x01: return "VC_HEADER";
        case 0x02: return "VC_INPUT_TERMINAL";
        case 0x03: return "VC_OUTPUT_TERMINAL";
        case 0x04: return "VC_SELECTOR_UNIT";
        case 0x05: return "VC_PROCESSING_UNIT";
        case 0x06: return "VC_EXTENSION_UNIT";
        case 0x07: return "VC_ENCODING_UNIT";
        default: return "Unknown VC descriptor";
    }
}

static const char *vs_subtype_name(uint8_t value) {
    switch (value) {
        case 0x01: return "VS_INPUT_HEADER";
        case 0x02: return "VS_OUTPUT_HEADER";
        case 0x03: return "VS_STILL_IMAGE_FRAME";
        case 0x04: return "VS_FORMAT_UNCOMPRESSED";
        case 0x05: return "VS_FRAME_UNCOMPRESSED";
        case 0x06: return "VS_FORMAT_MJPEG";
        case 0x07: return "VS_FRAME_MJPEG";
        case 0x0A: return "VS_FORMAT_MPEG2TS";
        case 0x0C: return "VS_FORMAT_DV";
        case 0x0D: return "VS_COLORFORMAT";
        case 0x10: return "VS_FORMAT_FRAME_BASED";
        case 0x11: return "VS_FRAME_FRAME_BASED";
        case 0x12: return "VS_FORMAT_STREAM_BASED";
        default: return "Unknown VS descriptor";
    }
}

static void print_guid(const uint8_t *guid) {
    // USB Video Class GUIDs use the normal GUID byte layout: the first three
    // fields are little-endian, followed by eight bytes in wire order.
    printf("%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-",
           guid[3], guid[2], guid[1], guid[0], guid[5], guid[4],
           guid[7], guid[6], guid[8], guid[9]);
    for (size_t index = 10; index < 16; ++index) {
        printf("%02X", guid[index]);
    }
}

static void print_fourcc_if_present(const uint8_t *guid) {
    char text[5] = {0};
    int printable = 1;
    for (size_t index = 0; index < 4; ++index) {
        text[index] = (char)guid[index];
        if (guid[index] < 0x20 || guid[index] > 0x7E) {
            printable = 0;
        }
    }
    if (printable) {
        printf(" (fourcc '%s')", text);
    }
}

static void print_advertised_controls(const char *label,
                                      const uint8_t *bitmap,
                                      size_t byteCount,
                                      const char *const *names,
                                      size_t nameCount,
                                      unsigned indent) {
    print_indent(indent);
    printf("%s bitmap (%zu bytes): ", label, byteCount);
    print_bytes_inline(bitmap, byteCount);
    putchar('\n');

    int any = 0;
    for (size_t bit = 0; bit < nameCount; ++bit) {
        if (bitmap_bit(bitmap, byteCount, (unsigned)bit)) {
            print_indent(indent + 1);
            printf("bit %zu: %s\n", bit, names[bit] != NULL ? names[bit] : "Reserved/unknown");
            any = 1;
        }
    }
    for (unsigned bit = (unsigned)nameCount; bit < byteCount * 8; ++bit) {
        if (bitmap_bit(bitmap, byteCount, bit)) {
            print_indent(indent + 1);
            printf("bit %u: Unknown/reserved control bit\n", bit);
            any = 1;
        }
    }
    if (!any) {
        print_indent(indent + 1);
        puts("No advertised controls.");
    }
}

static void parse_camera_terminal(const uint8_t *descriptor, size_t length) {
    static const char *const controls[] = {
        "CT_SCANNING_MODE_CONTROL",
        "CT_AE_MODE_CONTROL",
        "CT_AE_PRIORITY_CONTROL",
        "CT_EXPOSURE_TIME_ABSOLUTE_CONTROL",
        "CT_EXPOSURE_TIME_RELATIVE_CONTROL",
        "CT_FOCUS_ABSOLUTE_CONTROL",
        "CT_FOCUS_RELATIVE_CONTROL",
        "CT_IRIS_ABSOLUTE_CONTROL",
        "CT_IRIS_RELATIVE_CONTROL",
        "CT_ZOOM_ABSOLUTE_CONTROL",
        "CT_ZOOM_RELATIVE_CONTROL",
        "CT_PANTILT_ABSOLUTE_CONTROL",
        "CT_PANTILT_RELATIVE_CONTROL",
        "CT_ROLL_ABSOLUTE_CONTROL",
        "CT_ROLL_RELATIVE_CONTROL",
        "Reserved",
        "CT_FOCUS_AUTO_CONTROL",
        "CT_PRIVACY_CONTROL",
        "CT_FOCUS_SIMPLE_CONTROL",
        "CT_WINDOW_CONTROL",
        "CT_REGION_OF_INTEREST_CONTROL",
    };

    if (length < 8) {
        puts("    Truncated Camera Terminal descriptor.");
        return;
    }
    printf("    Camera Terminal ID: %u, terminal type: 0x%04X\n",
           descriptor[3], read_le16(descriptor + 4));
    if (length < 15) {
        puts("    No Camera Terminal control bitmap (descriptor is truncated). ");
        return;
    }
    uint8_t controlSize = descriptor[14];
    if ((size_t)15 + controlSize > length) {
        printf("    Invalid/truncated Camera Terminal bControlSize %u.\n", controlSize);
        return;
    }
    print_advertised_controls("Camera Terminal bmControls", descriptor + 15,
                              controlSize, controls, sizeof(controls) / sizeof(controls[0]), 2);
}

static void parse_processing_unit(const uint8_t *descriptor, size_t length) {
    static const char *const controls[] = {
        "PU_BRIGHTNESS_CONTROL",
        "PU_CONTRAST_CONTROL",
        "PU_HUE_CONTROL",
        "PU_SATURATION_CONTROL",
        "PU_SHARPNESS_CONTROL",
        "PU_GAMMA_CONTROL",
        "PU_WHITE_BALANCE_TEMPERATURE_CONTROL",
        "PU_WHITE_BALANCE_COMPONENT_CONTROL",
        "PU_BACKLIGHT_COMPENSATION_CONTROL",
        "PU_GAIN_CONTROL",
        "PU_POWER_LINE_FREQUENCY_CONTROL",
        "PU_HUE_AUTO_CONTROL",
        "PU_WHITE_BALANCE_TEMPERATURE_AUTO_CONTROL",
        "PU_WHITE_BALANCE_COMPONENT_AUTO_CONTROL",
        "PU_DIGITAL_MULTIPLIER_CONTROL",
        "PU_DIGITAL_MULTIPLIER_LIMIT_CONTROL",
        "PU_ANALOG_VIDEO_STANDARD_CONTROL",
        "PU_ANALOG_LOCK_STATUS_CONTROL",
        "PU_CONTRAST_AUTO_CONTROL",
    };

    if (length < 8) {
        puts("    Truncated Processing Unit descriptor.");
        return;
    }
    printf("    Processing Unit ID: %u, source ID: %u\n", descriptor[3], descriptor[4]);
    uint8_t controlSize = descriptor[7];
    if ((size_t)8 + controlSize > length) {
        printf("    Invalid/truncated Processing Unit bControlSize %u.\n", controlSize);
        return;
    }
    print_advertised_controls("Processing Unit bmControls", descriptor + 8,
                              controlSize, controls, sizeof(controls) / sizeof(controls[0]), 2);
}

static void parse_extension_unit(const uint8_t *descriptor, size_t length) {
    if (length < 23) {
        puts("    Truncated Extension Unit descriptor.");
        return;
    }
    uint8_t unitID = descriptor[3];
    uint8_t numberOfControls = descriptor[20];
    uint8_t inputPins = descriptor[21];
    size_t controlSizeOffset = (size_t)22 + inputPins;
    if (controlSizeOffset >= length) {
        puts("    Invalid/truncated Extension Unit source list.");
        return;
    }
    uint8_t controlSize = descriptor[controlSizeOffset];
    size_t bitmapOffset = controlSizeOffset + 1;
    if (bitmapOffset + controlSize > length) {
        puts("    Invalid/truncated Extension Unit control bitmap.");
        return;
    }

    printf("    Extension Unit ID: %u\n", unitID);
    printf("    GUID: ");
    print_guid(descriptor + 4);
    putchar('\n');
    printf("    Number of controls: %u; input pins: %u; source IDs:", numberOfControls, inputPins);
    for (uint8_t index = 0; index < inputPins; ++index) {
        printf(" %u", descriptor[22 + index]);
    }
    putchar('\n');

    print_indent(2);
    printf("Extension Unit bmControls (%u bytes): ", controlSize);
    print_bytes_inline(descriptor + bitmapOffset, controlSize);
    putchar('\n');
    int any = 0;
    for (unsigned bit = 0; bit < controlSize * 8; ++bit) {
        if (bitmap_bit(descriptor + bitmapOffset, controlSize, bit)) {
            print_indent(3);
            printf("bit %u: vendor-defined Extension Unit control\n", bit);
            any = 1;
        }
    }
    if (!any) {
        print_indent(3);
        puts("No advertised Extension Unit control bits.");
    }
}

static void parse_vc_descriptor(const uint8_t *descriptor, size_t length) {
    if (length < 3) {
        return;
    }
    uint8_t subtype = descriptor[2];
    printf("  UVC VC %s (0x%02X), %zu bytes\n", vc_subtype_name(subtype), subtype, length);
    switch (subtype) {
        case 0x01:
            if (length >= 12) {
                printf("    UVC version: 0x%04X; VC collection length: %u; clock: %u Hz; streaming interfaces:",
                       read_le16(descriptor + 3), read_le16(descriptor + 5), read_le32(descriptor + 7));
                uint8_t count = descriptor[11];
                for (uint8_t index = 0; index < count && (size_t)12 + index < length; ++index) {
                    printf(" %u", descriptor[12 + index]);
                }
                putchar('\n');
            }
            break;
        case 0x02:
            parse_camera_terminal(descriptor, length);
            break;
        case 0x05:
            parse_processing_unit(descriptor, length);
            break;
        case 0x06:
            parse_extension_unit(descriptor, length);
            break;
        default:
            break;
    }
    print_indent(2);
    fputs("Raw: ", stdout);
    print_bytes_inline(descriptor, length);
    putchar('\n');
}

static void print_frame_intervals(const uint8_t *descriptor, size_t length) {
    if (length < 26) {
        puts("    Truncated UVC frame descriptor.");
        return;
    }
    uint8_t intervalType = descriptor[25];
    if (intervalType == 0) {
        if (length < 38) {
            puts("    Truncated continuous frame interval range.");
            return;
        }
        uint32_t minimum = read_le32(descriptor + 26);
        uint32_t maximum = read_le32(descriptor + 30);
        uint32_t step = read_le32(descriptor + 34);
        printf("    Frame intervals (100 ns): continuous %u..%u step %u\n", minimum, maximum, step);
        return;
    }
    size_t available = (length - 26) / 4;
    size_t count = intervalType < available ? intervalType : available;
    printf("    Frame intervals (%zu discrete, 100 ns):", count);
    for (size_t index = 0; index < count; ++index) {
        uint32_t interval = read_le32(descriptor + 26 + index * 4);
        if (interval == 0) {
            printf(" 0");
        } else {
            printf(" %u (%.3f fps)", interval, 10000000.0 / (double)interval);
        }
    }
    putchar('\n');
}

static void parse_standard_frame_descriptor(const uint8_t *descriptor, size_t length) {
    if (length < 26) {
        puts("    Truncated UVC frame descriptor.");
        return;
    }
    uint16_t width = read_le16(descriptor + 5);
    uint16_t height = read_le16(descriptor + 7);
    uint32_t defaultInterval = read_le32(descriptor + 21);
    printf("    Frame index: %u; %ux%u; default interval: %u (%.3f fps)\n",
           descriptor[3], width, height, defaultInterval,
           defaultInterval == 0 ? 0.0 : 10000000.0 / (double)defaultInterval);
    print_frame_intervals(descriptor, length);
}

static void parse_frame_based_frame_descriptor(const uint8_t *descriptor, size_t length) {
    // UVC VS_FRAME_FRAME_BASED differs from uncompressed/MJPEG frames: it has
    // no dwMaxVideoFrameBufferSize, and includes dwBytesPerLine after
    // bFrameIntervalType.
    if (length < 26) {
        puts("    Truncated frame-based UVC frame descriptor.");
        return;
    }
    uint16_t width = read_le16(descriptor + 5);
    uint16_t height = read_le16(descriptor + 7);
    uint32_t defaultInterval = read_le32(descriptor + 17);
    uint8_t intervalType = descriptor[21];
    uint32_t bytesPerLine = read_le32(descriptor + 22);
    printf("    Frame index: %u; %ux%u; default interval: %u (%.3f fps); bytes per line: %u\n",
           descriptor[3], width, height, defaultInterval,
           defaultInterval == 0 ? 0.0 : 10000000.0 / (double)defaultInterval,
           bytesPerLine);
    if (intervalType == 0) {
        if (length < 38) {
            puts("    Truncated continuous frame interval range.");
            return;
        }
        printf("    Frame intervals (100 ns): continuous %u..%u step %u\n",
               read_le32(descriptor + 26), read_le32(descriptor + 30), read_le32(descriptor + 34));
        return;
    }
    size_t available = (length - 26) / 4;
    size_t count = intervalType < available ? intervalType : available;
    printf("    Frame intervals (%zu discrete, 100 ns):", count);
    for (size_t index = 0; index < count; ++index) {
        uint32_t interval = read_le32(descriptor + 26 + index * 4);
        printf(" %u (%.3f fps)", interval,
               interval == 0 ? 0.0 : 10000000.0 / (double)interval);
    }
    putchar('\n');
}

static void parse_vc_or_vs_format_guid(const uint8_t *descriptor, size_t length) {
    if (length < 21) {
        puts("    Truncated UVC format GUID.");
        return;
    }
    printf("    Format index: %u; declared frame descriptors: %u; GUID: ", descriptor[3], descriptor[4]);
    print_guid(descriptor + 5);
    print_fourcc_if_present(descriptor + 5);
    putchar('\n');
}

static void parse_vs_descriptor(const uint8_t *descriptor, size_t length) {
    if (length < 3) {
        return;
    }
    uint8_t subtype = descriptor[2];
    printf("  UVC VS %s (0x%02X), %zu bytes\n", vs_subtype_name(subtype), subtype, length);
    switch (subtype) {
        case 0x01:
            if (length >= 13) {
                printf("    Formats: %u; VS collection length: %u; endpoint: 0x%02X; terminal link: %u\n",
                       descriptor[3], read_le16(descriptor + 4), descriptor[6], descriptor[8]);
            }
            break;
        case 0x04: // Uncompressed
        case 0x10: // Frame based (UVC 1.5)
            parse_vc_or_vs_format_guid(descriptor, length);
            break;
        case 0x06: // MJPEG
            if (length >= 7) {
                printf("    MJPEG format index: %u; declared frame descriptors: %u; default frame: %u\n",
                       descriptor[3], descriptor[4], descriptor[6]);
            }
            break;
        case 0x05: // Uncompressed frame
        case 0x07: // MJPEG frame
            parse_standard_frame_descriptor(descriptor, length);
            break;
        case 0x11: // Frame-based frame
            parse_frame_based_frame_descriptor(descriptor, length);
            break;
        default:
            break;
    }
    print_indent(2);
    fputs("Raw: ", stdout);
    print_bytes_inline(descriptor, length);
    putchar('\n');
}

static void parse_iad(const uint8_t *descriptor, size_t length) {
    if (length < 8) {
        puts("Interface Association Descriptor (truncated)");
        return;
    }
    printf("Interface Association: first interface %u, count %u, class 0x%02X (%s), subclass 0x%02X, protocol 0x%02X\n",
           descriptor[2], descriptor[3], descriptor[4], usb_class_name(descriptor[4]), descriptor[5], descriptor[6]);
}

static void parse_interface(const uint8_t *descriptor, size_t length) {
    if (length < 9) {
        puts("Interface Descriptor (truncated)");
        return;
    }
    const char *details = "";
    if (descriptor[5] == kUSBClassVideo) {
        details = video_subclass_name(descriptor[6]);
    } else if (descriptor[5] == 0x01) {
        details = audio_subclass_name(descriptor[6]);
    }
    printf("Interface %u alt %u: class 0x%02X (%s), subclass 0x%02X, protocol 0x%02X, endpoints %u%s%s\n",
           descriptor[2], descriptor[3], descriptor[5], usb_class_name(descriptor[5]),
           descriptor[6], descriptor[7], descriptor[4], details[0] == '\0' ? "" : " — ", details);
}

static void parse_endpoint(const uint8_t *descriptor, size_t length) {
    if (length < 7) {
        puts("Endpoint Descriptor (truncated)");
        return;
    }
    uint8_t address = descriptor[2];
    printf("Endpoint 0x%02X: %s, %s, max packet %u, interval %u\n", address,
           (address & 0x80) != 0 ? "IN" : "OUT", transfer_type_name(descriptor[3]),
           read_le16(descriptor + 4) & 0x07FF, descriptor[6]);
}

static void parse_configuration(const uint8_t *bytes, size_t availableLength, unsigned configIndex) {
    if (availableLength < 9 || bytes[1] != kUSBDescriptorTypeConfiguration) {
        fprintf(stderr, "Configuration %u is missing/truncated.\n", configIndex);
        return;
    }
    uint16_t totalLength = read_le16(bytes + 2);
    if (totalLength > availableLength) {
        fprintf(stderr, "Configuration %u reports %u bytes, but only %zu are accessible; clamping.\n",
                configIndex, totalLength, availableLength);
        totalLength = (uint16_t)availableLength;
    }

    printf("\n=== Configuration %u ===\n", configIndex);
    printf("Raw configuration descriptor: %u bytes\n", totalLength);
    print_hex(bytes, totalLength, 1);
    printf("Configuration value: %u; interfaces: %u; attributes: 0x%02X; MaxPower: %u mA\n\n",
           bytes[5], bytes[4], bytes[7], (unsigned)bytes[8] * 2);

    printf("Decoded descriptors\n");
    uint8_t currentClass = 0;
    uint8_t currentSubclass = 0;
    size_t offset = 0;
    while (offset + 2 <= totalLength) {
        uint8_t length = bytes[offset];
        uint8_t type = bytes[offset + 1];
        if (length < 2 || offset + length > totalLength) {
            fprintf(stderr, "Malformed descriptor at offset 0x%04zx (length %u); stopping.\n", offset, length);
            break;
        }
        const uint8_t *descriptor = bytes + offset;
        printf("[0x%04zx] ", offset);
        switch (type) {
            case kUSBDescriptorTypeConfiguration:
                puts("Configuration Descriptor");
                break;
            case kUSBDescriptorTypeInterfaceAssociation:
                parse_iad(descriptor, length);
                break;
            case kUSBDescriptorTypeInterface:
                parse_interface(descriptor, length);
                if (length >= 9) {
                    currentClass = descriptor[5];
                    currentSubclass = descriptor[6];
                }
                break;
            case kUSBDescriptorTypeEndpoint:
                parse_endpoint(descriptor, length);
                break;
            case kUSBDescriptorTypeClassSpecificInterface:
                if (currentClass == kUSBClassVideo && currentSubclass == kUSBVideoSubclassControl) {
                    parse_vc_descriptor(descriptor, length);
                } else if (currentClass == kUSBClassVideo && currentSubclass == kUSBVideoSubclassStreaming) {
                    parse_vs_descriptor(descriptor, length);
                } else {
                    printf("Class-specific interface descriptor for class 0x%02X/subclass 0x%02X (%u bytes): ",
                           currentClass, currentSubclass, length);
                    print_bytes_inline(descriptor, length);
                    putchar('\n');
                }
                break;
            case kUSBDescriptorTypeClassSpecificEndpoint:
                printf("Class-specific endpoint descriptor (%u bytes): ", length);
                print_bytes_inline(descriptor, length);
                putchar('\n');
                break;
            default:
                printf("Descriptor type 0x%02X (%u bytes): ", type, length);
                print_bytes_inline(descriptor, length);
                putchar('\n');
                break;
        }
        offset += length;
    }
}

static int registry_number(io_registry_entry_t service, CFStringRef key, uint64_t *result) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        if (value != NULL) {
            CFRelease(value);
        }
        return 0;
    }
    Boolean converted = CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, result);
    CFRelease(value);
    return converted;
}

static void registry_string(io_registry_entry_t service, CFStringRef key, const char *label, int sensitive) {
    if (sensitive && !include_identifiers) {
        printf("%s: <redacted; rerun with --include-identifiers>\n", label);
        return;
    }

    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
        char buffer[1024];
        if (CFStringGetCString((CFStringRef)value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            printf("%s: %s\n", label, buffer);
        }
    }
    if (value != NULL) {
        CFRelease(value);
    }
}

static void print_cached_device_fields(io_registry_entry_t service) {
    uint64_t value = 0;
    puts("Cached device descriptor fields (from IORegistry; no USB transfer)");
    registry_string(service, CFSTR("USB Vendor Name"), "Manufacturer", 0);
    registry_string(service, CFSTR("USB Product Name"), "Product", 1);
    registry_string(service, CFSTR("USB Serial Number"), "Serial", 1);
    if (registry_number(service, CFSTR("idVendor"), &value)) {
        printf("Vendor ID: 0x%04llX\n", (unsigned long long)value);
    }
    if (registry_number(service, CFSTR("idProduct"), &value)) {
        printf("Product ID: 0x%04llX\n", (unsigned long long)value);
    }
    if (registry_number(service, CFSTR("bcdUSB"), &value)) {
        printf("USB version (bcdUSB): 0x%04llX\n", (unsigned long long)value);
    }
    if (registry_number(service, CFSTR("bcdDevice"), &value)) {
        printf("Device version (bcdDevice): 0x%04llX\n", (unsigned long long)value);
    }
    if (registry_number(service, CFSTR("bDeviceClass"), &value)) {
        printf("Device class: 0x%02llX (%s)\n", (unsigned long long)value, usb_class_name((uint8_t)value));
    }
    if (registry_number(service, CFSTR("bDeviceSubClass"), &value)) {
        printf("Device subclass: 0x%02llX\n", (unsigned long long)value);
    }
    if (registry_number(service, CFSTR("bDeviceProtocol"), &value)) {
        printf("Device protocol: 0x%02llX\n", (unsigned long long)value);
    }
    if (registry_number(service, CFSTR("bMaxPacketSize0"), &value)) {
        printf("Endpoint 0 max packet size: %llu\n", (unsigned long long)value);
    }
    if (registry_number(service, CFSTR("bNumConfigurations"), &value)) {
        printf("Configurations: %llu\n", (unsigned long long)value);
    }
    if (registry_number(service, CFSTR("kUSBCurrentConfiguration"), &value)) {
        printf("Current configuration: %llu\n", (unsigned long long)value);
    }
    if (include_identifiers) {
        if (registry_number(service, CFSTR("locationID"), &value)) {
            printf("Location ID: 0x%08llX\n", (unsigned long long)value);
        }
    } else {
        puts("Location ID: <redacted; rerun with --include-identifiers>");
    }
    putchar('\n');
}

static CFMutableDictionaryRef create_device_matching_dictionary(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL) {
        return NULL;
    }
    int32_t vendor = kDJIVendorID;
    int32_t product = kPocket4ProductID;
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
        return NULL;
    }
    CFDictionarySetValue(matching, CFSTR("idVendor"), vendorNumber);
    CFDictionarySetValue(matching, CFSTR("idProduct"), productNumber);
    CFRelease(vendorNumber);
    CFRelease(productNumber);
    return matching;
}

int main(int argc, char *argv[]) {
    if (argc == 2 && strcmp(argv[1], "--include-identifiers") == 0) {
        include_identifiers = 1;
    } else if (argc != 1) {
        fprintf(stderr, "Usage: %s [--include-identifiers]\n", argv[0]);
        return EXIT_FAILURE;
    }

    CFMutableDictionaryRef matching = create_device_matching_dictionary();
    if (matching == NULL) {
        fputs("Unable to create an IOUSBHostDevice matching dictionary.\n", stderr);
        return EXIT_FAILURE;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "IOServiceGetMatchingServices failed: 0x%08X\n", kr);
        return EXIT_FAILURE;
    }
    io_service_t service = IOIteratorNext(iterator);
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "DJI device %04X:%04X was not found.\n", kDJIVendorID, kPocket4ProductID);
        IOObjectRelease(iterator);
        return EXIT_FAILURE;
    }

    puts("DJI Osmo Pocket 4 USB cached-descriptor inspector");
    puts("Safety: no USB device open, no control transfer, no state-changing request.\n");
    if (!include_identifiers) {
        puts("Privacy: device product, serial, and USB location are redacted by default.\n");
    }
    print_cached_device_fields(service);

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kr = IOCreatePlugInInterfaceForService(service,
                                            kIOUSBDeviceUserClientTypeID,
                                            kIOCFPlugInInterfaceID,
                                            &plugin,
                                            &score);
    if (kr != kIOReturnSuccess || plugin == NULL) {
        fprintf(stderr, "Unable to create the IOUSBLib plug-in interface: 0x%08X\n", kr);
        IOObjectRelease(service);
        IOObjectRelease(iterator);
        return EXIT_FAILURE;
    }

    IOUSBDeviceInterface **device = NULL;
    HRESULT queryResult = (*plugin)->QueryInterface(plugin,
                                                     CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                                     (LPVOID)&device);
    IODestroyPlugInInterface(plugin);
    if (queryResult != S_OK || device == NULL) {
        fprintf(stderr, "Unable to query IOUSBDeviceInterface: 0x%08X\n", (unsigned int)queryResult);
        IOObjectRelease(service);
        IOObjectRelease(iterator);
        return EXIT_FAILURE;
    }

    // The IOUSBLib header documents this exact call as safe without opening the
    // USB device.  It returns macOS's cached descriptor, not a new bus request.
    IOUSBConfigurationDescriptorPtr configuration = NULL;
    kr = (*device)->GetConfigurationDescriptorPtr(device, 0, &configuration);
    if (kr != kIOReturnSuccess || configuration == NULL) {
        fprintf(stderr, "GetConfigurationDescriptorPtr(0) failed: 0x%08X\n", kr);
        (*device)->Release(device);
        IOObjectRelease(service);
        IOObjectRelease(iterator);
        return EXIT_FAILURE;
    }

    const uint8_t *bytes = (const uint8_t *)configuration;
    uint16_t totalLength = read_le16(bytes + 2);
    parse_configuration(bytes, totalLength, 0);

    (*device)->Release(device);
    IOObjectRelease(service);
    IOObjectRelease(iterator);
    return EXIT_SUCCESS;
}
