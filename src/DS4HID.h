#import "Capture.h"
#import <IOKit/hid/IOHIDManager.h>

void matchBluetoothPads(IOHIDManagerRef manager);
void receiveDS4Report(Capture *capture, uint32_t reportID, uint8_t *bytes, CFIndex size);
