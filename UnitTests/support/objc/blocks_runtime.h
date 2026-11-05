/*
 * Declarations for the blocks runtime that ships inside GNUstep Base 1.29
 * (libgnustep-base exports _Block_copy and _Block_release). The Ubuntu
 * development package omits this header, which GNUstepBase/GSVersionMacros.h
 * includes when the compiler has blocks enabled.
 */
#ifdef __cplusplus
extern "C" {
#endif
void *_Block_copy(const void *);
void _Block_release(const void *);
const char *_Block_get_types(const void *);
#ifdef __cplusplus
}
#endif
#define Block_copy(x) ((__typeof__(x))_Block_copy((const void *)(x)))
#define Block_release(x) _Block_release((const void *)(x))
