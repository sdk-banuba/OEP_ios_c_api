#import "BNBOffscreenEffectPlayer.h"

#import <Accelerate/Accelerate.h>
#include <interfaces/offscreen_effect_player.hpp>

#include "effect_player.hpp"
#include "offscreen_render_target.h"

#include <bnb/utility_manager.h>

@implementation BNBOffscreenEffectPlayer
{
    NSUInteger _width;
    NSUInteger _height;

    effect_player_sptr m_ep;
    offscreen_render_target_sptr m_ort;
    offscreen_effect_player_sptr m_oep;

    utility_manager_holder_t* m_utility;
}

- (id)init
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"-init is not a valid initializer for the class BNBOffscreenEffectPlayer"
                                 userInfo:nil];
}

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  manualAudio:(BOOL)manual
                        token:(NSString*)token
                resourcePaths:(NSArray<NSString *> *)resourcePaths;
{
    _width = width;
    _height = height;

    std::vector<std::string> path_to_resources;
    for (id object in resourcePaths) {
        path_to_resources.push_back(std::string([(NSString*)object UTF8String]));
    }
    std::unique_ptr<const char*[]> res_paths = std::make_unique<const char*[]>(path_to_resources.size() + 1);
    std::transform(path_to_resources.begin(), path_to_resources.end(), res_paths.get(), [](const auto& s) { return s.c_str(); });
    res_paths.get()[path_to_resources.size()] = nullptr;
    m_utility = bnb_utility_manager_init(res_paths.get(), [token UTF8String], nullptr);

    m_ep = bnb::oep::effect_player::create(width, height);
    m_ort = std::make_shared<bnb::offscreen_render_target>();
    m_oep = bnb::oep::interfaces::offscreen_effect_player::create(m_ep, m_ort, width, height);
    
    m_oep->surface_changed(width, height);
    return self;
}

- (void)processImage:(CVPixelBufferRef)pixelBuffer inputOrientation:(EPOrientation)orientation completion:(BNBOEPImageReadyBlock _Nonnull)completion
{
    pixel_buffer_sptr pixelBuffer_sprt([self convertImage:pixelBuffer]);
    auto get_pixel_buffer_callback = [self, pixelBuffer, completion](image_processing_result_sptr result) {
        if (result != nullptr) {
            auto render_callback = [self, completion](std::optional<rendered_texture_t> texture_id) {
                if (texture_id.has_value()) {
                    CVPixelBufferRef retBuffer = (CVPixelBufferRef)texture_id.value();

                    if (completion) {
                        CVPixelBufferRef retBufferConverted = [self processOutputInBGRA:retBuffer];
                        completion(retBufferConverted);
                        CVPixelBufferRelease(retBufferConverted);
                    }

                    CVPixelBufferRelease(retBuffer);
                }
            };
            result->get_texture(render_callback);
        }
    };
    
    auto input_orientation = [self getInputOrientation:orientation];
    m_oep->process_image_async(pixelBuffer_sprt, input_orientation, true, get_pixel_buffer_callback, bnb::oep::interfaces::rotation::deg270);
}

- (pixel_buffer_sptr)convertImage:(CVPixelBufferRef)pixelBuffer
{
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    pixel_buffer_sptr img;

    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: {
            CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            uint8_t* lumo = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
            uint8_t* chromo = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
            int bufferWidth = CVPixelBufferGetWidth(pixelBuffer);
            int bufferHeight = CVPixelBufferGetHeight(pixelBuffer);

            // Retain twice. Each plane will release once.
            CVPixelBufferRetain(pixelBuffer);
            CVPixelBufferRetain(pixelBuffer);

            using ns = bnb::oep::interfaces::pixel_buffer;
            ns::plane_data y_plane{std::shared_ptr<uint8_t>(lumo, [pixelBuffer](uint8_t*) {
                                       CVPixelBufferRelease(pixelBuffer);
                                   }),
                                   0,
                                   static_cast<int32_t>(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))};
            ns::plane_data uv_plane{std::shared_ptr<uint8_t>(chromo, [pixelBuffer](uint8_t*) {
                                        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                                        CVPixelBufferRelease(pixelBuffer);
                                    }),
                                    0,
                                    static_cast<int32_t>(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))};

            std::vector<ns::plane_data> planes{y_plane, uv_plane};
            img = ns::create(planes, bnb::oep::interfaces::image_format::nv12_bt709_full, bufferWidth, bufferHeight);
        } break;
        default:
            NSLog(@"ERROR TYPE : %d", pixelFormat);
            return nil;
    }
        return std::move(img);
}

- (void)loadEffect:(NSString* _Nonnull)effectName
{
    NSAssert(self->m_oep != nil, @"No OffscreenEffectPlayer");
    m_oep->load_effect(std::string([effectName UTF8String]));
}

- (void)unloadEffect
{
    NSAssert(self->m_oep != nil, @"No OffscreenEffectPlayer");
    m_oep->unload_effect();
}

- (void)callJsMethod:(NSString* _Nonnull)method withParam:(NSString* _Nonnull)param
{
    NSAssert(self->m_oep != nil, @"No OffscreenEffectPlayer");
    m_oep->call_js_method(std::string([method UTF8String]), std::string([param UTF8String]));
}

- (CVPixelBufferRef)processOutputInBGRA:(CVPixelBufferRef)inputPixelBuffer
{
    CVPixelBufferLockBaseAddress(inputPixelBuffer, kCVPixelBufferLock_ReadOnly);
    unsigned char* baseAddress = (unsigned char*) CVPixelBufferGetBaseAddress(inputPixelBuffer);
    auto width = CVPixelBufferGetWidth(inputPixelBuffer);
    auto height = CVPixelBufferGetHeight(inputPixelBuffer);
    auto bytesPerRow = CVPixelBufferGetBytesPerRow(inputPixelBuffer);

    NSDictionary* pixelAttributes = @{(id) kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef pixelBuffer = NULL;
    auto result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)(pixelAttributes),
        &pixelBuffer);
    NSParameterAssert(result == kCVReturnSuccess && pixelBuffer != NULL);

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void* rgbOut = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t rgbOutWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
    size_t rgbOutHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    size_t rgbOutBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);

    vImage_Buffer sourceBufferInfo = {
        .width = static_cast<vImagePixelCount>(width),
        .height = static_cast<vImagePixelCount>(height),
        .rowBytes = bytesPerRow,
        .data = baseAddress};
    vImage_Buffer outputBufferInfo = {
        .width = rgbOutWidth,
        .height = rgbOutHeight,
        .rowBytes = rgbOutBytesPerRow,
        .data = rgbOut};

    const uint8_t permuteMap[4] = {2, 1, 0, 3}; // Convert to BGRA pixel format

    vImagePermuteChannels_ARGB8888(&sourceBufferInfo, &outputBufferInfo, permuteMap, kvImageNoFlags);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    CVPixelBufferUnlockBaseAddress(inputPixelBuffer, kCVPixelBufferLock_ReadOnly);

    return pixelBuffer;
}

- (void)dealloc
{
    if (m_ep) {
        m_ep->surface_destroyed();
    }
    if (m_utility) {
        bnb_utility_manager_release(m_utility, nullptr);
        m_utility = nullptr;
    }
}

- (void)surfaceChanged:(NSUInteger)width withHeight:(NSUInteger)height
{
    if (m_oep) {
        m_oep->surface_changed(width, height);
    }
}
- (bnb::oep::interfaces::rotation)getInputOrientation:(EPOrientation)orientation{
    switch (orientation) {
        case EPOrientationAngles0:      return bnb::oep::interfaces::rotation::deg0;
        case EPOrientationAngles90:     return bnb::oep::interfaces::rotation::deg90;
        case EPOrientationAngles180:    return bnb::oep::interfaces::rotation::deg180;
        case EPOrientationAngles270:    return bnb::oep::interfaces::rotation::deg270;
    }
}

@end
