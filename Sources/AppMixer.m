#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <stdatomic.h>
#import <math.h>

typedef struct { AudioObjectID tap; AudioDeviceID device; AudioDeviceIOProcID proc; _Atomic(float) gain; _Atomic(bool) signal; float previous; } MMEngine;
static OSStatus mmRead(AudioObjectID object, AudioObjectPropertySelector key, AudioObjectPropertyScope scope, void *value, UInt32 size) {
    AudioObjectPropertyAddress a = {key,scope,0}; return AudioObjectGetPropertyData(object,&a,0,NULL,&size,value);
}
void mmStop(void *handle) {
    if (!handle) return; MMEngine *e = handle;
    if (e->device && e->proc) { AudioDeviceStop(e->device,e->proc); AudioDeviceDestroyIOProcID(e->device,e->proc); }
    if (e->device) AudioHardwareDestroyAggregateDevice(e->device);
    if (e->tap) AudioHardwareDestroyProcessTap(e->tap);
    free(e);
}
bool mmHealthy(void *handle) { return handle && atomic_load_explicit(&((MMEngine *)handle)->signal,memory_order_relaxed); }
void mmGain(void *handle, float gain) { if(handle) atomic_store_explicit(&((MMEngine *)handle)->gain, fmaxf(0,fminf(1,gain)), memory_order_relaxed); }
void *mmStart(const UInt32 *objects, UInt32 count, UInt32 output, float gain, int32_t *error) {
    if (@available(macOS 14.2,*)) {
        MMEngine *e = calloc(1,sizeof(MMEngine)); atomic_init(&e->gain,gain); atomic_init(&e->signal,false); e->previous = 1;
        OSStatus status = 0; CFStringRef uid = NULL;
        AudioStreamBasicDescription format = {0};
        status = mmRead(output,kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeOutput,&format,sizeof(format));
        if(status || format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32 || format.mChannelsPerFrame != 2) { *error = status ?: -70001; mmStop(e); return NULL; }
        status = mmRead(output,kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,&uid,sizeof(uid));
        if(status || !uid) { *error = status ?: -70002; mmStop(e); return NULL; }
        NSString *deviceUID = CFBridgingRelease(uid);
        NSMutableArray *processes = [NSMutableArray new]; for(UInt32 i=0;i<count;i++) [processes addObject:@(objects[i])];
        CATapDescription *tap = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
        tap.name = @"Mi Mac · volumen por app"; tap.privateTap = YES; tap.muteBehavior = CATapMutedWhenTapped;
        status = AudioHardwareCreateProcessTap(tap,&e->tap);
        if(status) { *error=status; mmStop(e); return NULL; }
        AudioStreamBasicDescription captured = {0};
        status = mmRead(e->tap,kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal,&captured,sizeof(captured));
        if(status || captured.mBitsPerChannel != 32 || !(captured.mFormatFlags & kAudioFormatFlagIsFloat) || captured.mChannelsPerFrame != 2 || (captured.mFormatFlags & kAudioFormatFlagIsNonInterleaved) || fabs(captured.mSampleRate-format.mSampleRate)>1) { *error=status ?: -70001; mmStop(e); return NULL; }
        NSDictionary *config = @{
            @kAudioAggregateDeviceNameKey: @"Mi Mac App Audio", @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES, @kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey:deviceUID, @kAudioSubDeviceInputChannelsKey:@0, @kAudioSubDeviceOutputChannelsKey:@2}],
            @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey:tap.UUID.UUIDString, @kAudioSubTapDriftCompensationKey:@YES}],
            @kAudioAggregateDeviceTapAutoStartKey:@YES
        };
        status=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config,&e->device);
        if(status) { *error=status; mmStop(e); return NULL; }
        status=AudioDeviceCreateIOProcIDWithBlock(&e->proc,e->device,NULL,^(const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot) {
            const AudioBuffer *source=NULL;
            for(UInt32 i=input->mNumberBuffers;i>0;i--) { const AudioBuffer *b=&input->mBuffers[i-1]; if(b->mNumberChannels==2 && b->mData) {source=b;break;} }
            bool signal=false;
            float target=atomic_load_explicit(&e->gain,memory_order_relaxed);
            UInt32 sourceFrames=source ? source->mDataByteSize/(2*sizeof(float)):0;
            UInt32 channelOffset=0;
            for(UInt32 b=0;b<output->mNumberBuffers;b++) {
                AudioBuffer *dest=&output->mBuffers[b];
                if(!dest->mData || !dest->mNumberChannels) continue;
                UInt32 frames=dest->mDataByteSize/(sizeof(float)*dest->mNumberChannels);
                float *samples=dest->mData; const float *in=source ? source->mData:NULL;
                for(UInt32 f=0;f<frames;f++) {
                    float ramp=e->previous+(target-e->previous)*f/fmaxf(1,frames-1);
                    for(UInt32 c=0;c<dest->mNumberChannels;c++) {
                        UInt32 channel=channelOffset+c;
                        if(in && f<sourceFrames && channel<2 && fabsf(in[f*2+channel])>0.000001f) signal=true;
                        samples[f*dest->mNumberChannels+c]=(in && f<sourceFrames && channel<2) ? in[f*2+channel]*ramp:0;
                    }
                }
                channelOffset+=dest->mNumberChannels;
            }
            if(signal) atomic_store_explicit(&e->signal,true,memory_order_relaxed);
            e->previous=target;
        });
        if(!status) status=AudioDeviceStart(e->device,e->proc);
        if(status) { *error=status; mmStop(e); return NULL; }
        *error=0; return e;
    }
    *error=-70003; return NULL;
}
