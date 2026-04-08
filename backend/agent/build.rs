fn main() {
    let now = chrono::Utc::now();
    println!(
        "cargo:rustc-env=KTTY_BUILD_TIME={}",
        now.format("%Y-%m-%d %H:%M UTC")
    );
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/");
}
