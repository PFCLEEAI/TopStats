// TempHelper.m - Apple Silicon Temperature Reader
// Uses IOHIDEventSystemClient to read actual CPU temperature sensors
// Compile: clang -Wall -framework IOKit -framework Foundation -o TempHelper TempHelper.m

#import <Foundation/Foundation.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>

// Type definitions for IOHIDEvent functions (not in public headers)
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

// IOHIDEvent type for temperature
#define kIOHIDEventTypeTemperature 15

// Function declarations for IOKit HID system
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef client, int64_t type, int32_t options, int64_t timeout);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
CFStringRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);

// Get field base for event type
#define IOHIDEventFieldBase(type) (type << 16)

// Create matching dictionary for temperature sensors
CFDictionaryRef createMatchingDict(int usagePage, int usage) {
    CFNumberRef usagePageRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usagePage);
    CFNumberRef usageRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);

    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {usagePageRef, usageRef};

    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);

    CFRelease(usagePageRef);
    CFRelease(usageRef);

    return matching;
}

// Read CPU temperature using the calibrated tcal sensor (matches CleanMyMac)
double getMaxCPUTemperature(void) {
    // Create HID event system client
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) {
        return -1.0;
    }

    // Match thermal sensors: usage page 0xff00 (Apple vendor), usage 5 (temperature)
    CFDictionaryRef matching = createMatchingDict(0xff00, 5);
    IOHIDEventSystemClientSetMatching(client, matching);
    CFRelease(matching);

    // Get all matching services
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) {
        CFRelease(client);
        return -1.0;
    }

    double tcalTemp = -999.0;   // Calibrated temperature sensor (preferred - matches CleanMyMac)
    double maxDieTemp = -999.0; // Maximum of all "tdie" sensors as fallback
    double maxPMUTemp = -999.0; // Maximum of any PMU sensor as last resort

    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);

        // Get sensor name
        CFStringRef productName = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        NSString *name = nil;
        if (productName) {
            name = (__bridge NSString *)productName;
        }

        // Read temperature event
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (event) {
            double temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
            CFRelease(event);

            // Only consider valid temperatures
            if (temp > 0 && temp < 150) {
                if (name) {
                    NSString *lowerName = [name lowercaseString];

                    // "PMU tcal" is the calibrated sensor - this is what CleanMyMac uses
                    // It's already calibrated, no offset needed
                    if ([lowerName containsString:@"tcal"]) {
                        tcalTemp = temp;
                    }

                    // "PMU tdie*" sensors are raw CPU die temperatures (fallback)
                    if ([lowerName containsString:@"tdie"]) {
                        if (temp > maxDieTemp) {
                            maxDieTemp = temp;
                        }
                    }

                    // Track max PMU temp as last resort fallback
                    if ([lowerName containsString:@"pmu"]) {
                        if (temp > maxPMUTemp) {
                            maxPMUTemp = temp;
                        }
                    }
                }
            }
        }

        if (productName) {
            CFRelease(productName);
        }
    }

    CFRelease(services);
    CFRelease(client);

    // Prefer tcal (calibrated) sensor - matches CleanMyMac exactly
    // No offset needed as tcal is already calibrated
    if (tcalTemp > 0) {
        return tcalTemp;
    } else if (maxDieTemp > 0) {
        return maxDieTemp;
    } else if (maxPMUTemp > 0) {
        return maxPMUTemp;
    }

    return -1.0;
}

// Continuously update temperature file
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *tempFile = @"/tmp/cpu_temp.txt";

        while (YES) {
            double temp = getMaxCPUTemperature();

            if (temp > 0 && temp < 150) {
                NSString *tempStr = [NSString stringWithFormat:@"%.0f", temp];
                NSError *error = nil;
                [tempStr writeToFile:tempFile atomically:YES encoding:NSUTF8StringEncoding error:&error];

                if (error) {
                    NSLog(@"Error writing temp file: %@", error);
                }
            }

            // Match the app's lightweight refresh cadence.
            [NSThread sleepForTimeInterval:5.0];
        }
    }
    return 0;
}
