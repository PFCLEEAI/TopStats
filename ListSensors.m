// ListSensors.m - List all HID temperature sensors on Apple Silicon
// Compile: clang -Wall -framework IOKit -framework Foundation -o ListSensors ListSensors.m

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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("=== Apple Silicon Temperature Sensors ===\n\n");

        // Create HID event system client
        IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) {
            printf("Error: Could not create HID event system client\n");
            return 1;
        }

        // Match thermal sensors: usage page 0xff00 (Apple vendor), usage 5 (temperature)
        CFDictionaryRef matching = createMatchingDict(0xff00, 5);
        IOHIDEventSystemClientSetMatching(client, matching);
        CFRelease(matching);

        // Get all matching services
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (!services) {
            printf("Error: No temperature sensors found\n");
            CFRelease(client);
            return 1;
        }

        CFIndex count = CFArrayGetCount(services);
        printf("Found %ld temperature sensors:\n\n", (long)count);

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
            double temp = -1.0;
            if (event) {
                temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
                CFRelease(event);
            }

            // Print sensor info
            printf("[%2ld] %-40s : %.1f C\n", (long)i, name ? [name UTF8String] : "(unknown)", temp);

            if (productName) {
                CFRelease(productName);
            }
        }

        CFRelease(services);
        CFRelease(client);

        printf("\n=== End of sensor list ===\n");
    }
    return 0;
}
