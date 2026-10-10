#pragma once

#import <Foundation/Foundation.h>
#import <mach/mach.h>

template <typename T>
static inline bool SafeRead(uintptr_t address, T &outVal) {
    if (!address) return false;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(
        mach_task_self(),
        static_cast<vm_address_t>(address),
        sizeof(T),
        reinterpret_cast<vm_address_t>(&outVal),
        &outSize
    );
    return (kr == KERN_SUCCESS && outSize == sizeof(T));
}

static inline bool SafeReadBytes(uintptr_t address, void *dest, size_t size) {
    if (!address || !dest || size == 0) return false;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(
        mach_task_self(),
        static_cast<vm_address_t>(address),
        size,
        reinterpret_cast<vm_address_t>(dest),
        &outSize
    );
    return (kr == KERN_SUCCESS && outSize == size);
}

template <typename T>
static inline bool SafeWrite(uintptr_t address, const T &val) {
    if (!address) return false;
    kern_return_t kr = vm_write(
        mach_task_self(),
        static_cast<vm_address_t>(address),
        reinterpret_cast<vm_offset_t>(&val),
        sizeof(T)
    );
    return (kr == KERN_SUCCESS);
}

static inline bool SafeWriteBytes(uintptr_t address, const void *src, size_t size) {
    if (!address || !src || size == 0) return false;
    kern_return_t kr = vm_write(
        mach_task_self(),
        static_cast<vm_address_t>(address),
        reinterpret_cast<vm_offset_t>(src),
        static_cast<mach_msg_type_number_t>(size)
    );
    return (kr == KERN_SUCCESS);
}
