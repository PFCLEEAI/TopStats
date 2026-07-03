// TempHelper.m - Apple Silicon Temperature Reader
// Uses IOHIDEventSystemClient to read actual CPU temperature sensors
// Compile: clang -O2 -Wall -framework IOKit -framework Foundation -o TempHelper TempHelper.m
// NOTE: compiled without ARC (build.sh passes no -fobjc-arc) — manual retain/release below.

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

// Sensor classification flags. A sensor named "PMU tcal" is both tcal and PMU,
// matching the original independent substring checks.
enum {
    SensorKindTcal = 1 << 0,
    SensorKindTdie = 1 << 1,
    SensorKindPMU  = 1 << 2,
};

// Cached HID client + classified sensor list. Creating the event-system client
// and re-classifying every sensor name each tick was the dominant cost of the
// original loop; the sensor set is fixed hardware, so build it once and reuse.
static IOHIDEventSystemClientRef gClient = NULL;
static CFArrayRef gServices = NULL;          // owns the service refs
static uint8_t *gKinds = NULL;               // classification per service index
static CFIndex gServiceCount = 0;
static IOHIDServiceClientRef gTcalService = NULL; // borrowed from gServices

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

static void teardownSensors(void) {
    gTcalService = NULL;
    gServiceCount = 0;
    if (gKinds) {
        free(gKinds);
        gKinds = NULL;
    }
    if (gServices) {
        CFRelease(gServices);
        gServices = NULL;
    }
    if (gClient) {
        CFRelease(gClient);
        gClient = NULL;
    }
}

static BOOL setupSensors(void) {
    teardownSensors();

    gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gClient) {
        return NO;
    }

    // Match thermal sensors: usage page 0xff00 (Apple vendor), usage 5 (temperature)
    CFDictionaryRef matching = createMatchingDict(0xff00, 5);
    IOHIDEventSystemClientSetMatching(gClient, matching);
    CFRelease(matching);

    gServices = IOHIDEventSystemClientCopyServices(gClient);
    if (!gServices) {
        teardownSensors();
        return NO;
    }

    gServiceCount = CFArrayGetCount(gServices);
    gKinds = calloc(gServiceCount > 0 ? gServiceCount : 1, sizeof(uint8_t));
    if (!gKinds) {
        teardownSensors();
        return NO;
    }

    for (CFIndex i = 0; i < gServiceCount; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, i);
        CFStringRef productName = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (!productName) {
            continue;
        }
        NSString *lowerName = [(__bridge NSString *)productName lowercaseString];
        uint8_t kind = 0;
        // "PMU tcal" is the calibrated sensor - this is what CleanMyMac uses
        if ([lowerName containsString:@"tcal"]) kind |= SensorKindTcal;
        // "PMU tdie*" sensors are raw CPU die temperatures (fallback)
        if ([lowerName containsString:@"tdie"]) kind |= SensorKindTdie;
        // Any PMU sensor is the last-resort fallback
        if ([lowerName containsString:@"pmu"])  kind |= SensorKindPMU;
        gKinds[i] = kind;
        if ((kind & SensorKindTcal) && !gTcalService) {
            gTcalService = service;
        }
        CFRelease(productName);
    }
    return YES;
}

static double readSensor(IOHIDServiceClientRef service) {
    IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
    if (!event) {
        return -1.0;
    }
    double temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
    CFRelease(event);
    // Only consider valid temperatures
    if (temp > 0 && temp < 150) {
        return temp;
    }
    return -1.0;
}

// Read CPU temperature using the calibrated tcal sensor (matches CleanMyMac).
// Same preference order as always: tcal, then max tdie, then max PMU.
double getMaxCPUTemperature(void) {
    if (!gClient && !setupSensors()) {
        return -1.0;
    }

    // Fast path: read only the calibrated tcal sensor, which is the value
    // actually reported on machines that have it.
    if (gTcalService) {
        double temp = readSensor(gTcalService);
        if (temp > 0) {
            return temp;
        }
    }

    double tcalTemp = -999.0;   // Calibrated temperature sensor (preferred - matches CleanMyMac)
    double maxDieTemp = -999.0; // Maximum of all "tdie" sensors as fallback
    double maxPMUTemp = -999.0; // Maximum of any PMU sensor as last resort

    for (CFIndex i = 0; i < gServiceCount; i++) {
        uint8_t kind = gKinds[i];
        if (!kind) {
            continue; // sensor never feeds the result; skip the event read
        }
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, i);
        double temp = readSensor(service);
        if (temp <= 0) {
            continue;
        }
        if (kind & SensorKindTcal) {
            tcalTemp = temp;
        }
        if ((kind & SensorKindTdie) && temp > maxDieTemp) {
            maxDieTemp = temp;
        }
        if ((kind & SensorKindPMU) && temp > maxPMUTemp) {
            maxPMUTemp = temp;
        }
    }

    // Prefer tcal (calibrated) sensor - matches CleanMyMac exactly
    if (tcalTemp > 0) {
        return tcalTemp;
    } else if (maxDieTemp > 0) {
        return maxDieTemp;
    } else if (maxPMUTemp > 0) {
        return maxPMUTemp;
    }

    // Every sensor failed — the cached services are likely stale (e.g. after
    // sleep/wake). Rebuild the client on the next attempt.
    teardownSensors();
    return -1.0;
}

// Continuously update temperature file
int main(int argc, const char *argv[]) {
    NSString *tempFile = @"/tmp/cpu_temp.txt";
    NSString *lastWritten = nil; // retained (no ARC)
    NSTimeInterval lastWriteTime = 0;

    while (YES) {
        @autoreleasepool {
            double temp = getMaxCPUTemperature();

            if (temp > 0 && temp < 150) {
                NSString *tempStr = [NSString stringWithFormat:@"%.0f", temp];
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

                // Skip the write when the rounded value is unchanged, but still
                // rewrite periodically so the file's mtime stays fresh. 50 s
                // threshold + 10 s ticks bounds the worst-case mtime age at
                // ~60 s (the old 60 s + 5 s ticks allowed ~65 s).
                if (lastWritten == nil
                    || ![tempStr isEqualToString:lastWritten]
                    || now - lastWriteTime >= 50) {
                    NSError *error = nil;
                    if ([tempStr writeToFile:tempFile atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
                        [lastWritten release];
                        lastWritten = [tempStr retain];
                        lastWriteTime = now;
                    } else if (error) {
                        NSLog(@"Error writing temp file: %@", error);
                    }
                }
            }
        }

        // CPU package temperature moves slowly and the title shows whole
        // degrees; a 10 s cadence halves the helper's steady-state CPU while
        // staying well inside the freshness bound above.
        [NSThread sleepForTimeInterval:10.0];
    }
    return 0;
}
