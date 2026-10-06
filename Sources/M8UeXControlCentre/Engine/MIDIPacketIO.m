//
//  MIDIPacketIO.m
//  M8U eX Control Centre
//

#import "MIDIPacketIO.h"

// The legacy packet-list functions are deprecated in favour of the UMP-based
// event list API, but they are still the only correct path for a MIDI 1.0
// class-compliant device. Silencing the deprecation here keeps the rest of the
// project warning-free without hiding the situation from anyone reading it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

double M8UHostTimeToSeconds(uint64_t hostTime) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    if (timebase.denom == 0) { return 0.0; }
    return (double)hostTime * (double)timebase.numer / (double)timebase.denom / 1e9;
}

uint64_t M8UHostTicksFromSeconds(double seconds) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    if (timebase.numer == 0) { return 0; }
    return (uint64_t)(seconds * 1e9 * (double)timebase.denom / (double)timebase.numer);
}

uint64_t M8UCurrentHostTime(void) {
    return mach_absolute_time();
}

/// CoreMIDI's packet list API requires a buffer whose exact capacity is passed
/// in; this is comfortably larger than any single MIDI 1.0 message we will ever
/// send (256 bytes plus framing). The arithmetic is a compile-time constant so
/// the stack array has a fixed, known size.
static const NSUInteger kM8UMaxMessageBytes = 256;
enum {
    kM8UPacketListCapacity =
        sizeof(MIDIPacketList) + sizeof(MIDIPacket) + 256 + 16
};

OSStatus M8USendMIDI1(MIDIPortRef outputPort,
                      MIDIEndpointRef destination,
                      const UInt8 *bytes,
                      NSUInteger length,
                      MIDITimeStamp timestamp) {
    if (outputPort == 0 || destination == 0 || bytes == NULL) { return kMIDIInvalidPort; }
    if (length == 0 || length > kM8UMaxMessageBytes) { return kMIDIInvalidPort; }

    UInt8 storage[kM8UPacketListCapacity];
    MIDIPacketList *packetList = (MIDIPacketList *)storage;

    MIDIPacket *packet = MIDIPacketListInit(packetList);
    packet = MIDIPacketListAdd(packetList,
                               (ByteCount)sizeof(storage),
                               packet,
                               timestamp,
                               (ByteCount)length,
                               bytes);
    if (packet == NULL) {
        // The message genuinely did not fit, which the size check above makes
        // impossible; report it rather than sending a truncated message.
        return kMIDIInvalidPort;
    }
    return MIDISend(outputPort, destination, packetList);
}

OSStatus M8UReceiveMIDI1(MIDIEndpointRef source,
                         const UInt8 *bytes,
                         NSUInteger length) {
    if (source == 0 || bytes == NULL) { return kMIDIInvalidPort; }
    if (length == 0 || length > kM8UMaxMessageBytes) { return kMIDIInvalidPort; }

    UInt8 storage[kM8UPacketListCapacity];
    MIDIPacketList *packetList = (MIDIPacketList *)storage;

    MIDIPacket *packet = MIDIPacketListInit(packetList);
    // Timestamp 0 means "now", which is right for a virtual source: the message
    // is being generated live, not scheduled.
    packet = MIDIPacketListAdd(packetList,
                               (ByteCount)sizeof(storage),
                               packet,
                               0,
                               (ByteCount)length,
                               bytes);
    if (packet == NULL) { return kMIDIInvalidPort; }

    return MIDIReceived(source, packetList);
}

UInt32 M8UPacketFrameCount(const MIDIPacketList *packetList) {
    if (packetList == NULL) { return 0; }
    return packetList->numPackets;
}

UInt32 M8UCopyPacketFrames(const MIDIPacketList *packetList, M8UPacketFrame *outFrames) {
    if (packetList == NULL || outFrames == NULL) { return 0; }

    UInt32 count = 0;
    const MIDIPacket *packet = &packetList->packet[0];
    for (UInt32 index = 0; index < packetList->numPackets; index++) {
        UInt32 length = packet->length;
        if (length > sizeof(outFrames[count].bytes)) {
            // A MIDI 1.0 packet cannot exceed 256 bytes on the wire; clamp
            // rather than overflow the frame buffer if a driver misbehaves.
            length = (UInt32)sizeof(outFrames[count].bytes);
        }
        M8UPacketFrame *frame = &outFrames[count];
        frame->length = length;
        frame->reserved = 0;
        frame->timestamp = packet->timeStamp;
        if (length > 0) {
            memcpy(frame->bytes, packet->data, length);
        }
        count++;
        packet = MIDIPacketNext(packet);
    }
    return count;
}

#pragma clang diagnostic pop
