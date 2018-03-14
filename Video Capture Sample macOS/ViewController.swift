//
//  ViewController.swift
//  Video Capture Sample macOS
//
//  Modified from iOS sample at https://developer.apple.com/documentation/accelerate/vimage/applying_vimage_operations_to_video_sample_buffers?language=objc
//

import Cocoa
import AVFoundation
import Accelerate.vImage

class ViewController: NSViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    @IBOutlet var imageView: NSImageView!
    
    var cgImageFormat = vImage_CGImageFormat(
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        colorSpace:  nil,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue),
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent)
    
    var converter: vImageConverter?
    
    var sourceBuffers = [vImage_Buffer]()
    var destinationBuffer = vImage_Buffer()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        configureSession()
        captureSession.startRunning()
    }
    
    deinit {
        free(destinationBuffer.data)
    }
    
    let captureSession = AVCaptureSession()
    
    func configureSession() {
        captureSession.sessionPreset = AVCaptureSession.Preset.photo
        print(AVCaptureDevice.devices(for: AVMediaType.video))
        let defaultVideoCamera = AVCaptureDevice.default(for: AVMediaType.video)
        
        do {
            let input = try AVCaptureDeviceInput(device: defaultVideoCamera!)
            captureSession.addInput(input)
        } catch {
            print("can't access camera")
            return
        }
        
        let videoOutput = AVCaptureVideoDataOutput()
        
        let dataOutputQueue = DispatchQueue(label: "video data queue",
                                            qos: .userInitiated,
                                            attributes: [],
                                            autoreleaseFrequency: .workItem)
        
        videoOutput.setSampleBufferDelegate(self,
                                            queue: dataOutputQueue)
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            captureSession.startRunning()
        }
    }
    
    // AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer,
                                     CVPixelBufferLockFlags.readOnly)
        
        displayEqualizedPixelBuffer(pixelBuffer: pixelBuffer)
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer,
                                       CVPixelBufferLockFlags.readOnly)
    }
    
    func displayEqualizedPixelBuffer(pixelBuffer: CVPixelBuffer) {
        var error = kvImageNoError
        
        if converter == nil {
            let cvImageFormat = vImageCVImageFormat_CreateWithCVPixelBuffer(pixelBuffer).takeRetainedValue()
            let deviceRGBSpace = CGColorSpaceCreateDeviceRGB()
            vImageCVImageFormat_SetColorSpace(cvImageFormat,
                                              deviceRGBSpace)
            // Thank you Simon Gladman! https://stackoverflow.com/a/49275464/719690
            vImageCVImageFormat_SetChromaSiting(cvImageFormat,
                                                kCVImageBufferChromaLocation_Center)

            if let unmanagedConverter = vImageConverter_CreateForCVToCGImageFormat(
                cvImageFormat,
                &cgImageFormat,
                nil,
                vImage_Flags(kvImagePrintDiagnosticsToConsole),
                &error) {
                
                guard error == kvImageNoError else {
                    return
                }
                
                converter = unmanagedConverter.takeRetainedValue()
            } else {
                return
            }
        }
        
        if sourceBuffers.isEmpty {
            let numberOfSourceBuffers = Int(vImageConverter_GetNumberOfSourceBuffers(converter!))
            sourceBuffers = [vImage_Buffer](repeating:vImage_Buffer(),
                                            count:numberOfSourceBuffers)
        }
        
        error = vImageBuffer_InitForCopyFromCVPixelBuffer(
            &sourceBuffers,
            converter!,
            pixelBuffer,
            vImage_Flags(kvImageNoAllocate))
        
        guard error == kvImageNoError else {
            return
        }
        
        
        if destinationBuffer.data == nil {
            error = vImageBuffer_Init(&destinationBuffer,
                                      UInt(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
                                      UInt(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
                                      cgImageFormat.bitsPerPixel,
                                      vImage_Flags(kvImageNoFlags))
            
            guard error == kvImageNoError else {
                return
            }
        }
        
        error = vImageConvert_AnyToAny(converter!,
                                       &sourceBuffers,
                                       &destinationBuffer,
                                       nil,
                                       vImage_Flags(kvImageNoFlags))
        
        guard error == kvImageNoError else {
            return
        }
        
        // MARK: - Histogram calculation, just for fun
        // wow this was painful!
        // see https://stackoverflow.com/questions/40562889/drawing-histogram-of-cgimage-in-swift-3/40563315#40563315
        
        let histogramBinsCount = 32
        let alpha = [vImagePixelCount](repeating: 0, count: histogramBinsCount)
        let red = [vImagePixelCount](repeating: 0, count: histogramBinsCount)
        let green = [vImagePixelCount](repeating: 0, count: histogramBinsCount)
        let blue = [vImagePixelCount](repeating: 0, count: histogramBinsCount)
        
        let alphaPtr = UnsafeMutablePointer<vImagePixelCount>(mutating: alpha) as UnsafeMutablePointer<vImagePixelCount>?
        let redPtr = UnsafeMutablePointer<vImagePixelCount>(mutating: red) as UnsafeMutablePointer<vImagePixelCount>?
        let greenPtr = UnsafeMutablePointer<vImagePixelCount>(mutating: green) as UnsafeMutablePointer<vImagePixelCount>?
        let bluePtr = UnsafeMutablePointer<vImagePixelCount>(mutating: blue) as UnsafeMutablePointer<vImagePixelCount>?
        
        let rgba = [redPtr, greenPtr, bluePtr, alphaPtr]
        
        let histogram = UnsafeMutablePointer<UnsafeMutablePointer<vImagePixelCount>?>(mutating: rgba)
        //        error = vImageHistogramCalculation_ARGB8888(&sourceBuffers, histogram, UInt32(kvImageNoFlags))
        
        error = vImageHistogramCalculation_ARGBFFFF(&sourceBuffers, histogram, UInt32(histogramBinsCount), 0.0, 1.0, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else {
            return
        }
        
        print("red")
        for thecount in red {
            print (thecount)
        }
        print("green")
        for thecount in green {
            print (thecount)
        }
        print("blue")
        for thecount in blue {
            print (thecount)
        }
        
        // MARK: - Histogram equalization, for display
        error = vImageEqualization_ARGB8888(&destinationBuffer,
                                            &destinationBuffer,
                                            vImage_Flags(kvImageLeaveAlphaUnchanged))
        
        guard error == kvImageNoError else {
            return
        }
        
        let cgImage = vImageCreateCGImageFromBuffer(
            &destinationBuffer,
            &cgImageFormat,
            nil,
            nil,
            vImage_Flags(kvImageNoFlags),
            &error)
        
        if let cgImage = cgImage, error == kvImageNoError {
            DispatchQueue.main.async {
                let size = NSMakeSize(CGFloat(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)), CGFloat(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)))
                self.imageView.image = NSImage(cgImage: cgImage.takeRetainedValue(), size: size)
            }
        }
    }

}

