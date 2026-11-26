fn main() {
    println!("cargo:rerun-if-env-changed=SPEKTRAFILM_EMBED_MANIFEST");
    println!("cargo:rustc-check-cfg=cfg(embed_bundle)");
    if std::env::var_os("SPEKTRAFILM_EMBED_MANIFEST").is_some() {
        println!("cargo:rustc-cfg=embed_bundle");
    }
}
