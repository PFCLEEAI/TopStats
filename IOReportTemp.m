// IOReportTemp.m - Read temperature via IOReport (like asitop/CleanMyMac)
// Compile: clang -Wall -framework IOKit -framework Foundation -o IOReportTemp IOReportTemp.m

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

// IOReport function declarations (private API)
typedef CFDictionaryRef IOReportSubscriptionRef;

extern IOReportSubscriptionRef IOReportCopyAllChannels(uint64_t, uint64_t);
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);

extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int64_t);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Get thermal channels
        CFDictionaryRef thermalChannels = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);

        if (!thermalChannels) {
            NSLog(@"Could not get thermal channels - trying all channels");
            thermalChannels = IOReportCopyAllChannels(0, 0);
        }

        if (!thermalChannels) {
            NSLog(@"Failed to get any IOReport channels");
            return 1;
        }

        // Create subscription
        CFMutableDictionaryRef subscriptionInfo = NULL;
        IOReportSubscriptionRef subscription = IOReportCreateSubscription(NULL,
            (__bridge CFMutableDictionaryRef)thermalChannels, &subscriptionInfo, 0, NULL);

        if (!subscription) {
            NSLog(@"Failed to create subscription");
            CFRelease(thermalChannels);
            return 1;
        }

        // Get samples
        CFDictionaryRef samples = IOReportCreateSamples(subscription, subscriptionInfo, NULL);

        if (!samples) {
            NSLog(@"Failed to get samples");
            CFRelease(subscription);
            CFRelease(thermalChannels);
            return 1;
        }

        // Iterate through samples looking for temperature data
        NSLog(@"=== IOReport Thermal Data ===");

        CFArrayRef channelList = CFDictionaryGetValue(samples, CFSTR("IOReportChannels"));
        if (channelList) {
            CFIndex count = CFArrayGetCount(channelList);
            for (CFIndex i = 0; i < count; i++) {
                CFDictionaryRef channel = CFArrayGetValueAtIndex(channelList, i);

                CFStringRef name = IOReportChannelGetChannelName(channel);
                CFStringRef group = IOReportChannelGetGroup(channel);
                CFStringRef subgroup = IOReportChannelGetSubGroup(channel);

                NSString *nameStr = (__bridge NSString *)name;
                NSString *groupStr = (__bridge NSString *)group;

                // Look for thermal-related channels
                if ([nameStr.lowercaseString containsString:@"temp"] ||
                    [nameStr.lowercaseString containsString:@"thermal"] ||
                    [groupStr.lowercaseString containsString:@"thermal"]) {

                    int64_t value = IOReportSimpleGetIntegerValue(channel, 0);
                    NSLog(@"[%@/%@] %@: %lld", groupStr, subgroup, nameStr, value);
                }
            }
        }

        CFRelease(samples);
        CFRelease(subscription);
        CFRelease(thermalChannels);

        NSLog(@"=== Done ===");
    }
    return 0;
}
