//
//  RecordAudio.swift
//
//  This is a Swift 3.0 class
//    that uses the iOS RemoteIO Audio Unit
//    to record audio input samples,
//  (should be instantiated as a singleton object.)
//
//  Created by Ronald Nicholson on 10/21/16.
//  Copyright © 2017 HotPaw Productions. All rights reserved.
//  BSD 2-clause license
//
import Foundation
import AVFoundation
import AudioUnit


let AUDIO_SAMPLE_RATE : Double = 16000
let AUDIO_FRAMES_PER_PACKET : UInt32 = 1
let AUDIO_CHANNELS_PER_FRAME : UInt32 = 1
let AUDIO_BITS_PER_CHANNEL : UInt32 = 16
let AUDIO_BYTES_PER_PACKET : UInt32 = 2
let AUDIO_BYTES_PER_FRAME : UInt32 = 2

// call setupAudioSessionForRecording() during controlling view load
// call startRecording() to start recording in a later UI call

typealias RIAudioActionCompletion = (Bool, NSError) -> Void

final class RecordAudio: NSObject {
    
    
    var audioComponent : AudioUnit?
    
    
    static let sharedInstance = RecordAudio()
    
    private override init(){ super.init()}
    
    
//    var audioUnit:   AudioUnit?

    var micPermission   =  false
    var sessionActive   =  false
    var isRecording     =  false
    var isAudioUnitRunning = false
    
    var avAudioPlayer : AVAudioPlayer!
    
    var sampleRate : Double = 44100.0    // default audio sample rate

    let circBuffSize = 32768        // lock-free circular fifo/buffer size
    var circBuffer   = [Float](repeating: 0, count: 32768)  // for incoming samples
    var circInIdx  : Int =  0
    var audioLevel : Float  = 0.0
    var recordedVoiceData = NSMutableData()
    var voiceDataLength: Int = 0
    var isReadyToPlay : Bool = false
    
    //for linear buffer
    let linearBuffSize = 32768        // lock-free linear fifo/buffer size
    var linearBuffer   = [Float](repeating: 0, count: 32768)  // for incoming samples
    var linearInIdx  : Int =  0
    
    
    private var hwSRate = 48000.0   // guess of device hardware sample rate
    private var micPermissionDispatchToken = 0
    private var interrupted = false     // for restart from audio interruption notification
    private var gTmp0: Int!

    func startRecording() {
      
        
            startAudioSession()
            startAudioUnit()
        
    }
    
    
    
    var numberOfChannels: Int       =  2
    
    private let outputBus: UInt32   =  0
    private let inputBus: UInt32    =  1
    
   
    
    /*func startAudioUnit() {
        var err: OSStatus = noErr
        
        if self.audioComponent == nil {
            setupAudioComponent()         // setup once
        }
        guard let au = self.audioComponent else { return }
        
        err = AudioUnitInitialize(au)
        gTmp0 = Int(err)
        if err != noErr { return }
        err = AudioOutputUnitStart(au)  // start
        
        gTmp0 = Int(err)
        if err == noErr {
            isRecording = true
        }
    }*/
    
    
     func startAudioUnit() {
        
        stopAudioUnit()
        setupAudioComponent()
        
        if let tempComponent = self.audioComponent {
            var status : OSStatus = AudioOutputUnitStart(tempComponent)
            
            if(status == 0){
                self.isAudioUnitRunning = true
                do{
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                }
                catch{
                    print("Error occurred: \(error.localizedDescription)")
                }
            }
        
        
        }
    }

    func startAudioSession() {
        
        let audioSession = AVAudioSession.sharedInstance()
        
        
        switch audioSession.recordPermission {
            
        case .undetermined:
            
            audioSession.requestRecordPermission({(granted: Bool)-> Void in
                if granted {
                    self.micPermission = true
                    self.initializeAudioSession()
                    return
                    // check for this flag and call from UI loop if needed
                } else {
                    self.gTmp0 += 1
                    // dispatch in main/UI thread an alert
                    //   informing that mic permission is not switched on
                    print("")
                }
            })
            
            break
        case .denied:
            debugPrint("Record Permission Denied")
            
            break
            
        case .granted:
            initializeAudioSession()
            break
            
        @unknown default:
            debugPrint("Could not Get Record Permission")
        }
        
    }
    
     func initializeAudioSession() {
        
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            
            try audioSession.setCategory(AVAudioSession.Category.playAndRecord)
            // choose 44100 or 48000 based on hardware rate
            // sampleRate = 44100.0
            /*
            var preferredIOBufferDuration = 0.0058      // 5.8 milliseconds = 256 samples
            hwSRate = audioSession.sampleRate           // get native hardware rate
            if hwSRate == 48000.0 { sampleRate = 48000.0 }  // set session to hardware rate
            if hwSRate == 48000.0 { preferredIOBufferDuration = 0.0053 }
            let desiredSampleRate = sampleRate
            try audioSession.setPreferredSampleRate(desiredSampleRate)
            try audioSession.setPreferredIOBufferDuration(preferredIOBufferDuration)
            */
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(AVAudioSession.interruptionNotification.rawValue),
                object: nil,
                queue: nil,
                using: myAudioSessionInterruptionHandler )
            
            // set and activate Audio Session
            
            try audioSession.setActive(true)
            
        } catch /* let error as NSError */ {
            // handle error here
        }
        
    }
    
  
    
  
    

    
   
    
     func setupAudioComponent() {
         
        var componentDesc:  AudioComponentDescription
        = AudioComponentDescription(
            componentType:          kAudioUnitType_Output,
            componentSubType:       kAudioUnitSubType_RemoteIO,
            componentManufacturer:  kAudioUnitManufacturer_Apple,
            componentFlags:         0,
            componentFlagsMask:     0 )
        
        var osErr: OSStatus = noErr
        
        let component: AudioComponent! = AudioComponentFindNext(nil, &componentDesc)
        
        
        var tempAudioUnit: AudioUnit?
        osErr = AudioComponentInstanceNew(component, &tempAudioUnit)
        
        checkErrorStatus(osErr: osErr)
         
         guard let tempAudioComponent = tempAudioUnit else {
             debugPrint("audioComponent not initiaziled")
             return
         }
        
        self.audioComponent = tempAudioComponent
         
        var flag : UInt32 = 1
        
        
        osErr = AudioUnitSetProperty(tempAudioComponent,
                                     kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input,
                                     inputBus,
                                     &flag,
                                     UInt32(MemoryLayout<UInt32>.size))
        osErr = AudioUnitSetProperty(tempAudioComponent,
                                     kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Output,
                                     outputBus,
                                     &flag,
                                     UInt32(MemoryLayout<UInt32>.size))
        
        // Set format to 32-bit Floats, linear PCM
        let nc = 2  // 2 channel stereo
        var streamFormatDesc:AudioStreamBasicDescription = AudioStreamBasicDescription(
            mSampleRate:        AUDIO_SAMPLE_RATE,
            mFormatID:          kAudioFormatLinearPCM,
            mFormatFlags:       ( kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked ),
            //mBytesPerPacket:    AUDIO_BYTES_PER_PACKET,
            //mFramesPerPacket:   AUDIO_FRAMES_PER_PACKET,
            //mBytesPerFrame:     AUDIO_BYTES_PER_FRAME,
            //mChannelsPerFrame:  AUDIO_CHANNELS_PER_FRAME,
            //mBitsPerChannel:    AUDIO_BITS_PER_CHANNEL,
            //mReserved: 0
            
            mBytesPerPacket:    UInt32(nc * MemoryLayout<UInt32>.size),
            mFramesPerPacket:   1,
            mBytesPerFrame:     UInt32(nc * MemoryLayout<UInt32>.size),
            mChannelsPerFrame:  UInt32(nc),
            mBitsPerChannel:    UInt32(8 * (MemoryLayout<UInt32>.size)),
            mReserved:          UInt32(0)
        )
         
         let audioFormat = AVAudioFormat(
                     commonFormat: AVAudioCommonFormat.pcmFormatInt16,   // pcmFormatInt16, pcmFormatFloat32,
                     sampleRate: Double(sampleRate),                     // 44100.0 48000.0
                     channels:AVAudioChannelCount(2),                    // 1 or 2
                     interleaved: true )                                 // true for interleaved stereo
         
         osErr = AudioUnitSetProperty(tempAudioComponent,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      outputBus,
                                      &streamFormatDesc,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        
        osErr = AudioUnitSetProperty(tempAudioComponent,
                                     kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Output,
                                     inputBus,
                                     &streamFormatDesc,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        
        var inputCallbackStruct
        = AURenderCallbackStruct(inputProc: recordingCallback,
                                 inputProcRefCon:
                                    UnsafeMutableRawPointer(Unmanaged.passUnretained(RecordAudio.sharedInstance).toOpaque()))
        
        osErr = AudioUnitSetProperty(tempAudioComponent,
                                     AudioUnitPropertyID(kAudioOutputUnitProperty_SetInputCallback),
                                     AudioUnitScope(kAudioUnitScope_Global),
                                     inputBus,
                                     &inputCallbackStruct,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        checkErrorStatus(osErr: osErr)
        
        
        var outputCallbackStruct = AURenderCallbackStruct(inputProc: playingCallback, inputProcRefCon:
                                                            UnsafeMutableRawPointer(Unmanaged.passUnretained(RecordAudio.sharedInstance).toOpaque()))
        
        
        
        osErr = AudioUnitSetProperty(tempAudioComponent,
                                     AudioUnitPropertyID(kAudioUnitProperty_SetRenderCallback),
                                     AudioUnitScope(kAudioUnitScope_Global),
                                     outputBus,
                                     &outputCallbackStruct,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        
        checkErrorStatus(osErr: osErr)
        
        // Ask CoreAudio to allocate buffers for us on render.
        //   Is this true by default?
        
         var one_ui32: UInt32 = 1
        osErr = AudioUnitSetProperty(tempAudioComponent,
                                     AudioUnitPropertyID(kAudioUnitProperty_ShouldAllocateBuffer),
                                     AudioUnitScope(kAudioUnitScope_Output),
                                     inputBus,
                                     &one_ui32,
                                     UInt32(MemoryLayout<UInt32>.size))
        
        checkErrorStatus(osErr: osErr)
        //configure the audio session
         let sessionInstance = AVAudioSession.sharedInstance()
         var error : NSError
         
         do {
         try sessionInstance.setCategory(.playAndRecord, mode: .default)
         
         } catch {
         print("error in audio category setting \(error)")
         }
         
         do {
         try sessionInstance.setActive(true)
         
         } catch {
         print("error in audio active setting \(error)")
         }
         
         osErr = AudioUnitInitialize(audioComponent!)
         //  checkErrorStatus(osErr: OSErr)
    
     }
    
    let recordingCallback: AURenderCallback = { (
        
        inRefCon,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        frameCount,
        ioData ) -> OSStatus in
        
        let audioObject = unsafeBitCast(inRefCon, to: RecordAudio.self)
        var err: OSStatus = noErr
        
        // set mData to nil, AudioUnitRender() should be allocating buffers
        let buffer = AudioBuffer(
            mNumberChannels: UInt32(1),
            mDataByteSize: frameCount * 2,
            mData: malloc(Int(frameCount) * 2))
        
        var bufferList = AudioBufferList()
        bufferList.mNumberBuffers = 1
        bufferList.mBuffers = buffer
        
        var status : OSStatus!

        if let au = audioObject.audioComponent {
            status = AudioUnitRender(au,
                                  ioActionFlags,
                                  inTimeStamp,
                                  inBusNumber,
                                  frameCount,
                                  &bufferList)
        }
        
        if let tempComponent = audioObject.audioComponent {
            
            status = AudioUnitRender(tempComponent, ioActionFlags, inTimeStamp, inBusNumber, frameCount, &bufferList)
            
            RecordAudio.checkErrorStatus(osErr: status)
            
            if(status != noErr) {
                return status
            }

        }
        
        
        
        
        print("I am watching the buffer list \(bufferList)")
        
    
        audioObject.recordedVoiceData.resetBytes(in: NSMakeRange(0, audioObject.voiceDataLength))
        audioObject.recordedVoiceData.append(bufferList.mBuffers.mData!, length: Int(bufferList.mBuffers.mDataByteSize))
        //audioObject.voiceDataLength += Int(bufferList.mBuffers.mDataByteSize)
        //audioObject.processMicrophoneBuffer( inputDataList: &bufferList, frameCount: UInt32(frameCount) )
        return noErr
    }
    
    
    
    
    //for playing the audio
    let playingCallback: AURenderCallback = { (
        inRefCon,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        frameCount,
        ioData) -> OSStatus in
        
        let audioObject = unsafeBitCast(inRefCon, to: RecordAudio.self)
        var buffer = ioData?.pointee.mBuffers
        var err: OSStatus = noErr
        
        audioObject.isReadyToPlay = true
        
        let delay = DispatchTime.now() + 0.005
        DispatchQueue.main.asyncAfter(deadline: delay) {
            let size = UInt32(buffer?.mDataByteSize ?? 0)
            //memcpy(buffer?.mData, audioObject.recordedVoiceData.bytes, Int(size));
            //buffer?.mDataByteSize = size;
        }
        
    
        
     /*   UInt32 size = MIN(audioBuffer->mDataByteSize, callBufferLength);
            memcpy(audioBuffer->mData, callPlayBuffer, size);
            audioBuffer->mDataByteSize = size;*/
        
        //var outputBuffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ioData))![0]

       //let outputBuffer = UnsafeMutableAudioBufferListPointer(ioData)
       // let outputBuffer = ioData?.pointee.mBuffers.mData
        
      //  let size = UInt32(outputBuffer.mDataByteSize)
      //  memcpy(outputBuffer.mData, audioObject.recordedVoiceData.bytes, Int(size));
      //  outputBuffer.mDataByteSize = size;
        //audioObject.recordedVoiceData.replaceBytes(in: NSMakeRange(0, Int(size)), withBytes: nil)
        return 0
        
     
    }
    
    
    func isAudioUnitStarted() -> Bool{
        
        return self.isAudioUnitRunning
    }
    
    func processMicrophoneBuffer(   // process RemoteIO Buffer from mic input
        inputDataList : UnsafeMutablePointer<AudioBufferList>,
        frameCount : UInt32 )
    {
        let inputDataPtr = UnsafeMutableAudioBufferListPointer(inputDataList)
        let mBuffers : AudioBuffer = inputDataPtr[0]
        let count = Int(frameCount)
        
        // Microphone Input Analysis
        // let data      = UnsafePointer<Int16>(mBuffers.mData)
        let bufferPointer = UnsafeMutableRawPointer(mBuffers.mData)
        if let bptr = bufferPointer {
            let dataArray = bptr.assumingMemoryBound(to: Float.self)
            var sum : Float = 0.0
            var j = self.circInIdx
            let m = self.circBuffSize
            for i in 0..<(count/2) {
                let x = Float(dataArray[i+i  ])   // copy left  channel sample
                let y = Float(dataArray[i+i+1])   // copy right channel sample
             //   print("inserting in buffer x : \(x)")
              //  print("inserting in buffer y : \(y)")
                self.circBuffer[j    ] = x
                self.circBuffer[j + 1] = y
                j += 2 ; if j >= m { j = 0 }                // into circular buffer
                sum += x * x + y * y
            }
            self.circInIdx = j              // circular index will always be less than size
            // measuredMicVol_1 = sqrt( Float(sum) / Float(count) ) // scaled volume
         //   print("I am checking the buffer \(circBuffer)")
            if sum > 0.0 && count > 0 {
                let tmp = 5.0 * (logf(sum / Float(count)) + 20.0)
                let r : Float = 0.2
                audioLevel = r * tmp + (1.0 - r) * audioLevel
            }
        }
    }
    
    
    func processLinearMicrophoneBuffer(   // process RemoteIO Buffer from mic input
        inputDataList : UnsafeMutablePointer<AudioBufferList>,
        frameCount : UInt32 )
    {
        let inputDataPtr = UnsafeMutableAudioBufferListPointer(inputDataList)
        let mBuffers : AudioBuffer = inputDataPtr[0]
        let count = Int(frameCount)
        
        // Microphone Input Analysis
        // let data      = UnsafePointer<Int16>(mBuffers.mData)
        let bufferPointer = UnsafeMutableRawPointer(mBuffers.mData)
        if let bptr = bufferPointer {
            let dataArray = bptr.assumingMemoryBound(to: Float.self)
            var sum : Float = 0.0
            var j = self.linearInIdx
            let m = self.linearBuffSize
            
            for i in 0..<count{
                let x = Float(dataArray[i])
                self.linearBuffer[j] = x
                j = j+1;
                if j >= m { j = 0 }
                sum += x * x
            }
                    
            self.linearInIdx = j              // circular index will always be less than size
            // measuredMicVol_1 = sqrt( Float(sum) / Float(count) ) // scaled volume
         //   print("I am checking the buffer \(circBuffer)")
            if sum > 0.0 && count > 0 {
                let tmp = 5.0 * (logf(sum / Float(count)) + 20.0)
                let r : Float = 0.2
                audioLevel = r * tmp + (1.0 - r) * audioLevel
            }
        }
    }
    
    func stopRecording() {
        if let tempComponent = self.audioComponent {
            AudioUnitUninitialize(tempComponent)
        }
        isRecording = false
    }
    
    func myAudioSessionInterruptionHandler(notification: Notification) -> Void {
        let interuptionDict = notification.userInfo
        if let interuptionType = interuptionDict?[AVAudioSessionInterruptionTypeKey] {
            let interuptionVal = AVAudioSession.InterruptionType(
                rawValue: (interuptionType as AnyObject).uintValue )
            if (interuptionVal == AVAudioSession.InterruptionType.began) {
                if (isRecording) {
                    stopRecording()
                    isRecording = false
                    let audioSession = AVAudioSession.sharedInstance()
                    do {
                        try audioSession.setActive(false)
                        sessionActive = false
                    } catch {
                    }
                    interrupted = true
                }
            } else if (interuptionVal == AVAudioSession.InterruptionType.ended) {
                if (interrupted) {
                    // potentially restart here
                }
            }
        }
    }
    
    func checkErrorStatus(osErr : OSStatus) {
        if(osErr != .zero) {
            print("instance status failed: \(osErr)")
        }
    }
    
    public class func checkErrorStatus(osErr : OSStatus) {
        if(osErr != .zero) {
            print("class status failed: \(osErr)")
        }
    }
    
    func stopAudioUnit(){
        
        if let tempComponent = self.audioComponent {
            var status : OSStatus = AudioOutputUnitStop(tempComponent)
            self.isReadyToPlay = false
            checkErrorStatus(osErr: status)
            releaseAudioUnit()
            self.isAudioUnitRunning = false
        }
        
    }
    
    func releaseAudioUnit(){
        if let tempComponent = self.audioComponent {
            var status : OSStatus = AudioUnitUninitialize(tempComponent)
            checkErrorStatus(osErr: status)
            
            status = AudioComponentInstanceDispose(tempComponent)
            checkErrorStatus(osErr: status)
            
            self.audioComponent = nil
        }
        
        
    }
    
    
    func dealloc() {
        self.avAudioPlayer = nil
    }
    
     
}

// end of class RecordAudio
