#import "HWRender.h"

#import <Accelerate/Accelerate.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <dlfcn.h>
#import <os/log.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // OpenGL ES is deprecated, not gone

/// Layout-identical to libretro's `struct retro_hw_render_callback` (the vendored snes9x
/// libretro.h predates its last fields).
typedef struct {
    unsigned context_type;
    void (*context_reset)(void);
    uintptr_t (*get_current_framebuffer)(void);
    void *(*get_proc_address)(const char *sym);
    bool depth;
    bool stencil;
    bool bottom_left_origin;
    unsigned version_major;
    unsigned version_minor;
    bool cache_context;
    void (*context_destroy)(void);
    bool debug_context;
} duo_hw_render_callback;

enum { DUO_HW_CONTEXT_OPENGLES2 = 3, DUO_HW_CONTEXT_OPENGLES3 = 4, DUO_HW_CONTEXT_OPENGLES_VERSION = 5 };

static duo_hw_render_callback request;
static bool requested;
static EAGLContext *context;
static GLuint framebuffer, colorBuffer, depthBuffer;
static GLint fbWidth, fbHeight;
static uint8_t *readback;          // RGBA8888, one frame
static bool started;

static os_log_t hw_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.kurast.duomulator", "hw-render"); });
    return log;
}

static uintptr_t get_current_framebuffer(void) { return framebuffer; }

static void *get_proc_address(const char *sym) { return dlsym(RTLD_DEFAULT, sym); }

bool duo_hw_set_render(void *data) {
    duo_hw_render_callback *cb = data;
    if (!cb) return false;
    if (cb->context_type != DUO_HW_CONTEXT_OPENGLES2 && cb->context_type != DUO_HW_CONTEXT_OPENGLES3 &&
        cb->context_type != DUO_HW_CONTEXT_OPENGLES_VERSION) {
        os_log_error(hw_log(), "unsupported hardware context type %u", cb->context_type);
        return false;
    }
    cb->get_current_framebuffer = get_current_framebuffer;
    cb->get_proc_address = get_proc_address;
    request = *cb;
    requested = true;
    return true;
}

bool duo_hw_requested(void) { return requested; }

bool duo_hw_start(int width, int height) {
    if (!requested) return false;
    EAGLRenderingAPI api = request.context_type == DUO_HW_CONTEXT_OPENGLES2 ? kEAGLRenderingAPIOpenGLES2
                                                                           : kEAGLRenderingAPIOpenGLES3;
    context = [[EAGLContext alloc] initWithAPI:api];
    if (!context || ![EAGLContext setCurrentContext:context]) {
        os_log_error(hw_log(), "couldn't create an OpenGL ES context");
        context = nil;
        return false;
    }
    fbWidth = width;
    fbHeight = height;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glGenRenderbuffers(1, &colorBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, colorBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorBuffer);
    if (request.depth || request.stencil) {
        glGenRenderbuffers(1, &depthBuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, depthBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthBuffer);
        if (request.stencil)
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depthBuffer);
    }
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        os_log_error(hw_log(), "framebuffer incomplete: 0x%x", status);
        duo_hw_stop();
        return false;
    }
    // Start black: GLideN64 doesn't draw the edge rows/columns outside its viewport, and
    // uninitialised renderbuffer memory would show there.
    glViewport(0, 0, width, height);
    glClearColor(0, 0, 0, 1);
    glClearDepthf(1);
    glClearStencil(0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    readback = malloc((size_t)width * (size_t)height * 4);
    if (request.context_reset) request.context_reset();
    started = true;
    os_log(hw_log(), "OpenGL ES %{public}s context, %dx%d framebuffer",
           api == kEAGLRenderingAPIOpenGLES3 ? "3" : "2", width, height);
    return true;
}

void duo_hw_make_current(void) {
    if (context && [EAGLContext currentContext] != context) [EAGLContext setCurrentContext:context];
}

void duo_hw_release_current(void) {
    if ([EAGLContext currentContext] == context) [EAGLContext setCurrentContext:nil];
}

bool duo_hw_read_frame(int width, int height, void *rgb565, size_t pitch) {
    if (!started || !readback || width <= 0 || height <= 0) return false;
    if (width > fbWidth) width = fbWidth;
    if (height > fbHeight) height = fbHeight;
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, readback);
    // GL's rows start at the bottom: convert row by row into top-first order.
    for (int y = 0; y < height; y++) {
        vImage_Buffer src = { readback + (size_t)(height - 1 - y) * width * 4, 1, (vImagePixelCount)width,
                              (size_t)width * 4 };
        vImage_Buffer dst = { (uint8_t *)rgb565 + (size_t)y * pitch, 1, (vImagePixelCount)width, pitch };
        vImageConvert_RGBA8888toRGB565(&src, &dst, kvImageNoFlags);
    }
    return true;
}

void duo_hw_stop(void) {
    if (context) {
        [EAGLContext setCurrentContext:context];
        if (started && request.context_destroy) request.context_destroy();
        if (depthBuffer) glDeleteRenderbuffers(1, &depthBuffer);
        if (colorBuffer) glDeleteRenderbuffers(1, &colorBuffer);
        if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
        [EAGLContext setCurrentContext:nil];
    }
    depthBuffer = colorBuffer = framebuffer = 0;
    context = nil;
    free(readback);
    readback = NULL;
    started = false;
    requested = false;
    memset(&request, 0, sizeof(request));
}
