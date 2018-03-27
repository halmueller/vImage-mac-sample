//
//  ViewController.m
//  vimage mac obj-c
//
//  Created by Hal Mueller on 3/17/18.
//  Copyright © 2018 Panopto. All rights reserved.
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>

@interface ViewController ()
@property (weak) IBOutlet NSTextFieldCell *differenceLabel;
@property (weak) IBOutlet NSImageView *imageView;
@property (weak) IBOutlet NSImageView *maxView;
@property (weak) IBOutlet NSImageView *minView;
@property (nonatomic, assign) vImageConverterRef cvConverter;
@property (nonatomic, assign) vImageCVImageFormatRef cvformat;
@property (nonatomic, assign) vImage_Buffer vImageSourceBuffer;
@property (nonatomic, assign) vImage_Buffer vEqualizedImageDestinationBuffer;
@property (nonatomic, assign) vImage_Buffer maxDestinationBuffer;
@property (nonatomic, assign) vImage_Buffer minDestinationBuffer;
@property (nonatomic, strong) NSImage *equalizedImage;
@property (nonatomic, strong) NSImage *maxImage;
@property (nonatomic, strong) NSImage *minImage;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self configureSession];
}

- (void)configureSession
{
    self.captureSession  = [AVCaptureSession new];
    self.captureSession.sessionPreset = AVCaptureSessionPresetPhoto;
    AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    
    NSError *nsError;
    AVCaptureDeviceInput *inputDevice = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&nsError];
    if (!inputDevice) {
        NSLog(@"%s %@", __PRETTY_FUNCTION__, nsError);
        return;
    }
    [self.captureSession addInput:inputDevice];
    
    AVCaptureVideoDataOutput *cameraOutput = [AVCaptureVideoDataOutput new];
    dispatch_queue_t dataQueue = dispatch_queue_create("video data queue", DISPATCH_QUEUE_SERIAL);
    [cameraOutput setSampleBufferDelegate:self queue:dataQueue];
    
    if ([self.captureSession canAddOutput:cameraOutput]) {
        [self.captureSession addOutput:cameraOutput];
        [self.captureSession startRunning];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)cmSampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    static NSUInteger count = 0;
    if (count++ % 30 == 0) {
        CVImageBufferRef cvImageBuffer = CMSampleBufferGetImageBuffer(cmSampleBuffer);
        
        if (CVPixelBufferLockBaseAddress(cvImageBuffer, 0) == kCVReturnSuccess) {
            NSDate *start = [NSDate new];
            [self handlePixelBuffer:cvImageBuffer];
            CVPixelBufferUnlockBaseAddress(cvImageBuffer, kvImageNoFlags);
            NSLog(@"%f", [start timeIntervalSinceNow] * -1);
        }
    }
}

- (void)handlePixelBuffer:(CVImageBufferRef) pixelBuffer
{
    // From the headers:
    // typedef CVBufferRef CVImageBufferRef;
    // typedef CVImageBufferRef CVPixelBufferRef;

    vImage_Error vimageError = kvImageNoError;
    vImage_CGImageFormat cgformat = {
        .bitsPerComponent = 8,
        .bitsPerPixel = 32,
        .bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst,
        .colorSpace = NULL,    //sRGB
        .renderingIntent = kCGRenderingIntentDefault
    };

    CGFloat imageWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
    CGFloat imageHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);

    if (self.cvConverter == nil) {
        // do all initialization here: converter, source buffer, destination buffers
        
        self.cvformat = vImageCVImageFormat_CreateWithCVPixelBuffer(pixelBuffer);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        vImageCVImageFormat_SetColorSpace(self.cvformat, colorSpace);
        vImageCVImageFormat_SetChromaSiting(self.cvformat, kCVImageBufferChromaLocation_Center);
        
        self.cvConverter = vImageConverter_CreateForCVToCGImageFormat(self.cvformat, &cgformat, nil, kvImagePrintDiagnosticsToConsole, &vimageError);
        if (vimageError != kvImageNoError) {
            NSLog(@"converter creation vimageError %zd", vimageError);
        }
        
    }
    
    // source buffer, gets the video feed from CoreVideo
    vimageError = vImageBuffer_InitForCopyFromCVPixelBuffer(&_vImageSourceBuffer, self.cvConverter, pixelBuffer, kvImageNoAllocate);
    if (vimageError != kvImageNoError) {
        NSLog(@"source vimageError %zd", vimageError);
    }
    
    // destination buffers, one for each operation (histogram EQ, max, min)
    vimageError = vImageBuffer_Init(&_vEqualizedImageDestinationBuffer, imageHeight, imageWidth, cgformat.bitsPerPixel, kvImagePrintDiagnosticsToConsole);
    vimageError = vImageBuffer_Init(&_maxDestinationBuffer, imageHeight, imageWidth, cgformat.bitsPerPixel, kvImagePrintDiagnosticsToConsole);
    vimageError = vImageBuffer_Init(&_minDestinationBuffer, imageHeight, imageWidth, cgformat.bitsPerPixel, kvImagePrintDiagnosticsToConsole);
    
    vimageError = vImageConvert_AnyToAny(self.cvConverter, &_vImageSourceBuffer, &_vEqualizedImageDestinationBuffer, nil, kvImagePrintDiagnosticsToConsole);
    vimageError = vImageConvert_AnyToAny(self.cvConverter, &_vImageSourceBuffer, &_maxDestinationBuffer, nil, kvImagePrintDiagnosticsToConsole);
    vimageError = vImageConvert_AnyToAny(self.cvConverter, &_vImageSourceBuffer, &_minDestinationBuffer, nil, kvImagePrintDiagnosticsToConsole);

    // histogram EQ, because I have a working Swift sample
    vimageError = vImageEqualization_ARGB8888(&_vEqualizedImageDestinationBuffer, &_vEqualizedImageDestinationBuffer, kvImagePrintDiagnosticsToConsole&kvImageLeaveAlphaUnchanged);
    if (vimageError != kvImageNoError) {
        NSLog(@"vImageEqualization_ARGB8888 vimageError %zd", vimageError);
    }

    // max and kernels
    // kernel dimensions must be odd numbers
    NSUInteger kernelWidth = (imageWidth/2) * 2 - 1;
    NSUInteger kernelHeight = (imageHeight/2) * 2 - 1;
    // FIXME: the vImageMax/Min calls are inefficient because temp buffer is allocated/freed on each call (passing nil as 3rd parameter). Fix it for production version
    // See discussion at https://developer.apple.com/documentation/accelerate/1509208-vimagescale_argbffff?language=objc
    vimageError = vImageMax_ARGB8888(&_maxDestinationBuffer, &_maxDestinationBuffer, nil, 0, 0, kernelHeight, kernelWidth, kvImagePrintDiagnosticsToConsole);
    if (vimageError != kvImageNoError) {
        NSLog(@"vImageMax_ARGB8888 vimageError %zd", vimageError);
    }
    vimageError = vImageMin_ARGB8888(&_minDestinationBuffer, &_minDestinationBuffer, nil, 0, 0, kernelHeight, kernelWidth, kvImagePrintDiagnosticsToConsole);
    if (vimageError != kvImageNoError) {
        NSLog(@"vImageMin_ARGB8888 vimageError %zd", vimageError);
    }

    // convert to CGImage and then to NSImage, all 3 destinations
    NSSize imageSize = NSMakeSize(imageWidth, imageHeight);
    CGImageRef equalizedCGImage = vImageCreateCGImageFromBuffer(&_vEqualizedImageDestinationBuffer, &cgformat, nil, nil, kvImagePrintDiagnosticsToConsole, &vimageError);
    if (vimageError != kvImageNoError) {
        NSLog(@"vImageCreateCGImageFromBuffer vimageError %zd", vimageError);
    }
    else {
        self.equalizedImage = [[NSImage alloc] initWithCGImage:equalizedCGImage size:imageSize];
    }
    CGImageRelease(equalizedCGImage);
    free(_vEqualizedImageDestinationBuffer.data);
    
    CGImageRef maxCGImage = vImageCreateCGImageFromBuffer(&_maxDestinationBuffer, &cgformat, nil, nil, kvImagePrintDiagnosticsToConsole, &vimageError);
    if (vimageError != kvImageNoError) {
        NSLog(@"vImageCreateCGImageFromBuffer vimageError %zd", vimageError);
    }
    else {
        self.maxImage = [[NSImage alloc] initWithCGImage:maxCGImage size:imageSize];
    }
    CGImageRelease(maxCGImage);
    free(_maxDestinationBuffer.data);
    
    CGImageRef minCGImage = vImageCreateCGImageFromBuffer(&_minDestinationBuffer, &cgformat, nil, nil, kvImagePrintDiagnosticsToConsole, &vimageError);
    if (vimageError != kvImageNoError) {
        NSLog(@"vImageCreateCGImageFromBuffer vimageError %zd", vimageError);
    }
    else {
        self.minImage = [[NSImage alloc] initWithCGImage:minCGImage size:imageSize];
    }
    CGImageRelease(minCGImage);
    free(_minDestinationBuffer.data);

    // look at the center
    double colorDifference = [self colorDifferenceAtX:imageWidth/2 y:imageHeight/2 imageA:self.maxImage imageB:self.minImage];

    // update the UI
    dispatch_async(dispatch_get_main_queue(), ^{
        self.imageView.image = self.equalizedImage;
        self.maxView.image = self.maxImage;
        self.minView.image = self.minImage;
        self.differenceLabel.objectValue = @(colorDifference);
    });
}

// In an Instruments trace 19 March 2018, this function was responsible for 2/3 of the compute time, mainly from -colorAtX:Y:image:.
- (double)colorDifferenceAtX:(CGFloat) x y:(CGFloat) y imageA:(NSImage *)imageA imageB:(NSImage *)imageB
{
    // Converts the color to the L*A*B* color space
    // This is a machine independent color space that represents colors with respect to
    // human perception.
    static CGFloat const LAB_WHITE_POINT[3] = {0.95, 1.0, 1.09};
    static CGFloat const LAB_BLACK_POINT[3] = {0.0, 0.0, 0.0};
    static CGFloat const LAB_RANGE[4]       = {-127.0, 127.0, -127.0, 127.0};
    static dispatch_once_t onceToken;
    static NSColorSpace *labColorSpace;
    dispatch_once(&onceToken, ^{
        CGColorSpaceRef labColorSpaceRef = CGColorSpaceCreateLab(LAB_WHITE_POINT, LAB_BLACK_POINT, LAB_RANGE);
        labColorSpace = [[NSColorSpace alloc] initWithCGColorSpace:labColorSpaceRef];
    });

    NSColor *colorA = [[self colorAtX:x y:y image:imageA] colorUsingColorSpace:labColorSpace];
    NSColor *colorB = [[self colorAtX:x y:y image:imageB] colorUsingColorSpace:labColorSpace];
    
    NSArray *componentsA = [self componentsFromColor:colorA];
    NSArray *componentsB = [self componentsFromColor:colorB];
    
    CGFloat sum = 0.0;
    
    for(NSUInteger i = 0; i < componentsA.count; i++)
    {
        // Compute the Euclidean distance by squaring the distances between each component
        CGFloat val = [componentsA[i] floatValue] - [componentsB[i] floatValue];
        sum += val * val;
    }
    
    // compute the square root to find the value of the Euclidean distance
    CGFloat squareRoot = sqrtf(sum);
    return squareRoot;
}

// Converts the NSColor's components to an NSArray for easier consumption.
-(NSArray *) componentsFromColor:(NSColor *)labColor
{
    NSInteger count = [labColor numberOfComponents];
    CGFloat * comps = malloc(sizeof(CGFloat) * count);
    [labColor getComponents:comps];
    
    NSMutableArray *arrayComps = [NSMutableArray arrayWithCapacity:count];
    for(NSUInteger i = 0; i < count; i++)
    {
        [arrayComps addObject:@(comps[i])];
    }
    
    free(comps);
    return [NSArray arrayWithArray:arrayComps];
}

// Extracts the color at (x, y) of a given CIImage.
-(NSColor *) colorAtX:(CGFloat) x y:(CGFloat) y image:(NSImage *)image
{
    [image lockFocus];
    NSColor *pixelColor = NSReadPixel(NSMakePoint(x, y));
    [image unlockFocus];
    return pixelColor;
}


@end
