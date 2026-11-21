#![cfg(target_os = "android")]

use jni::objects::{JClass, JString};
use jni::sys::jstring;
use jni::JNIEnv;

fn read(env: &mut JNIEnv, s: &JString) -> Option<String> {
    env.get_string(s).ok().map(|v| v.into())
}

fn out(env: &mut JNIEnv, text: String) -> jstring {
    match env.new_string(text) {
        Ok(s) => s.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn guarded<F: FnOnce() -> String + std::panic::UnwindSafe>(f: F) -> String {
    match std::panic::catch_unwind(f) {
        Ok(s) => s,
        Err(_) => "{\"error\":\"internal panic\"}".to_string(),
    }
}

const BRIDGE: &str = "dev.rustedproxy.app.RustBridge";

#[no_mangle]
pub extern "system" fn Java_dev_rustedproxy_app_RustBridge_nativeInit(
    mut env: JNIEnv,
    _class: JClass,
    dir: JString,
) -> jstring {
    let dir = read(&mut env, &dir).unwrap_or_default();
    let result = guarded(move || {
        let c = std::ffi::CString::new(dir).unwrap_or_default();
        take(crate::rp_init(c.as_ptr()))
    });
    out(&mut env, result)
}

#[no_mangle]
pub extern "system" fn Java_dev_rustedproxy_app_RustBridge_nativeStartEngine(
    mut env: JNIEnv,
    _class: JClass,
    cfg: JString,
) -> jstring {
    let Some(cfg) = read(&mut env, &cfg) else {
        return std::ptr::null_mut();
    };
    let result = guarded(move || {
        let ptr = crate::rp_engine_start(std::ffi::CString::new(cfg).unwrap_or_default().as_ptr());
        take(ptr)
    });
    out(&mut env, result)
}

#[no_mangle]
pub extern "system" fn Java_dev_rustedproxy_app_RustBridge_nativeStopEngine(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let _ = BRIDGE;
    let result = guarded(|| take(crate::rp_engine_stop()));
    out(&mut env, result)
}

#[no_mangle]
pub extern "system" fn Java_dev_rustedproxy_app_RustBridge_nativeStartTun(
    mut env: JNIEnv,
    _class: JClass,
    fd: jni::sys::jint,
    mtu: jni::sys::jint,
) -> jstring {
    let result = guarded(move || take(crate::rp_tun_start(fd, mtu as u32)));
    out(&mut env, result)
}

#[no_mangle]
pub extern "system" fn Java_dev_rustedproxy_app_RustBridge_nativeStopTun(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let result = guarded(|| take(crate::rp_tun_stop()));
    out(&mut env, result)
}

#[no_mangle]
pub extern "system" fn Java_dev_rustedproxy_app_RustBridge_nativeStatus(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let result = guarded(|| take(crate::rp_engine_status()));
    out(&mut env, result)
}

fn take(ptr: *mut std::os::raw::c_char) -> String {
    if ptr.is_null() {
        return "{\"error\":\"null\"}".to_string();
    }
    let text = unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_string_lossy()
        .to_string();
    crate::rp_free(ptr);
    text
}
