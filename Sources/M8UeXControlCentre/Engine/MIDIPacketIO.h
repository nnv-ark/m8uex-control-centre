//
//  MIDIPacketIO.h
//  M8U eX Control Centre
//
//  A deliberately small Objective-C layer that owns every call to the legacy
//  `MIDIPacketList` API.
//
//  Why this exists: CoreMIDI's packet-list functions are marked deprecated in
//  favour of `MIDIEventList` (Universal MIDI Packets), but a class-compliant
//  MIDI 1.0 interface such as the M8U eX delivers legacy packets, and the
//  packet-list API remains the correct, fully supported way to talk to one.
//  Containing the deprecation in C lets the Swift engine use a clean,
//  non-deprecated interface and keeps the build free of warnings.
//

#import <Foundation/Foundation.h>
#import <CoreMIDI/CoreMIDI.h>
#import <mach/mach_time.h>

NS_ASSUME_NONNULL_BEGIN

/// One packet's worth of MIDI bytes, flattened for Swift.
///
/// A packet list can hold several packets, and one logical MIDI message can be
/// split across them, so packet boundaries must survive the crossing into Swift
/// for the parser to frame messages correctly.
typedef struct M8UPacketFrame {
    /// Number of valid bytes in `bytes`.
    UInt32 length;
    /// Pad to 8-byte alignment before the payload.
    UInt32 reserved;
    /// CoreMIDI host timestamp for this packet.
    UInt64 timestamp;
    /// Packet payload, at most 256 bytes for MIDI 1.0.
    UInt8 bytes[256];
} M8UPacketFrame;

/// Converts a mach absolute time value into seconds.
double M8UHostTimeToSeconds(uint64_t hostTime);

/// Converts a duration in seconds into mach absolute time units.
uint64_t M8UHostTicksFromSeconds(double seconds);

/// The current mach absolute time, the clock domain CoreMIDI timestamps use.
uint64_t M8UCurrentHostTime(void);

/// Sends one MIDI 1.0 message to a destination.
///
/// @param outputPort  The output port created with `MIDIOutputPortCreate`.
/// @param destination The destination endpoint to send to.
/// @param bytes       Raw MIDI bytes. Running status is not permitted by
///                    CoreMIDI here, and this app never produces it.
/// @param length      Number of bytes in `bytes`, at most 256.
/// @param timestamp   Host time to schedule at, or 0 to send immediately.
/// @return `noErr` on success, or a CoreMIDI error code.
OSStatus M8USendMIDI1(MIDIPortRef outputPort,
                      MIDIEndpointRef destination,
                      const UInt8 *bytes,
                      NSUInteger length,
                      MIDITimeStamp timestamp);

/// Publishes a message from a virtual source so other apps can receive it.
///
/// @param source  The virtual source created with `MIDISourceCreate`.
/// @param bytes   Raw MIDI bytes.
/// @param length  Number of bytes in `bytes`, at most 256.
/// @return `noErr` on success, or a CoreMIDI error code.
OSStatus M8UReceiveMIDI1(MIDIEndpointRef source,
                         const UInt8 *bytes,
                         NSUInteger length);

/// Number of packets in a packet list, so the caller can size its buffer.
UInt32 M8UPacketFrameCount(const MIDIPacketList *packetList);

/// Flattens a packet list into an array of frames.
///
/// The packet list handed to a CoreMIDI read block is only valid for the
/// duration of that block and must be drained synchronously; this copies
/// everything the caller needs before control returns.
///
/// @param packetList The list handed to the read block.
/// @param outFrames  Receives one frame per packet; must have room for
///                   `M8UPacketFrameCount(packetList)` frames.
/// @return The number of frames written.
UInt32 M8UCopyPacketFrames(const MIDIPacketList *packetList, M8UPacketFrame *outFrames);

NS_ASSUME_NONNULL_END
