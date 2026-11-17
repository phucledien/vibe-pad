#import "DS4HID.h"

void matchBluetoothPads(IOHIDManagerRef manager) {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSNumber *pid in @[@0x05c4, @0x09cc]) {
        [matches addObject:@{ @kIOHIDVendorIDKey: @0x054c, @kIOHIDProductIDKey: pid,
                             @kIOHIDTransportKey: @"Bluetooth",
                             @kIOHIDPrimaryUsagePageKey: @1, @kIOHIDPrimaryUsageKey: @5 }];
    }
    IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matches);
}

void receiveDS4Report(Capture *capture, uint32_t reportID, uint8_t *bytes, CFIndex size) {
    if (size <= 0 || size > 1024 || reportID > 255) return;
    // Account for drivers that pass the report ID separately from its payload.
    size_t expected = inputLength(reportID);
    uint8_t normalized[1025];
    if ((expected && (size_t)size + 1 == expected) || bytes[0] != reportID) {
        normalized[0] = reportID;
        memcpy(normalized + 1, bytes, size);
        bytes = normalized;
        size++;
    }
    [capture receive:bytes length:size];
}
