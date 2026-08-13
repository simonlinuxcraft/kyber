use std::sync::Mutex;

use flutter_rust_bridge::frb;
use tokio_util::sync::CancellationToken;

use crate::frb_generated::{RustAutoOpaque, StreamSink};

use maxima::content::{
    downloader::ZipDownloader,
    zip::{CompressionType, ZipFileEntry},
};

#[frb(opaque)]
pub struct DownloaderHandle {
    inner: ZipDownloader,
    cancel: Mutex<CancellationToken>,
}

#[frb(non_opaque)]
#[derive(Clone, Debug)]
pub struct ZipEntryInfo {
    pub name: String,
    pub compressed_size: i64,
    pub uncompressed_size: i64,
    pub compression: String,
    pub data_offset: i64,
    pub crc32: u32,
}

fn entry_to_info(e: &ZipFileEntry) -> ZipEntryInfo {
    ZipEntryInfo {
        name: e.name().to_string(),
        compressed_size: *e.compressed_size(),
        uncompressed_size: *e.uncompressed_size(),
        compression: match e.compression_type() {
            CompressionType::None => "none".to_string(),
            CompressionType::Deflate => "deflate".to_string(),
            other => format!("{other:?}"),
        },
        data_offset: *e.data_offset(),
        crc32: *e.crc32(),
    }
}

pub async fn downloader_create(
    id: String,
    zip_url: String,
    output_dir: String,
) -> Result<RustAutoOpaque<DownloaderHandle>, String> {
    let dl = ZipDownloader::new(&id, &zip_url, output_dir)
        .await
        .map_err(|e| e.to_string())?;

    Ok(RustAutoOpaque::new(DownloaderHandle {
        inner: dl,
        cancel: Mutex::new(CancellationToken::new()),
    }))
}

pub async fn downloader_get_id(d: RustAutoOpaque<DownloaderHandle>) -> String {
    d.read().await.inner.id().to_string()
}

pub async fn downloader_list_entries(d: RustAutoOpaque<DownloaderHandle>) -> Vec<ZipEntryInfo> {
    d.read().await.inner.manifest()
        .entries()
        .iter()
        .map(entry_to_info)
        .collect()
}

// MAXIMA-LINUX-PORT-MOD 2026-08-13: reject zip entry names that would escape the
// downloader's output directory. maxima-lib's download_single_file does
// `self.path.join(entry.name())`, and Path::join with a rooted component
// discards the base entirely, so a crafted name can write anywhere the launcher
// can write. The zips are mod collections, i.e. user-generated content, so the
// name is untrusted input. Subdirectories stay allowed: download_single_file
// creates parent dirs and handles "dir/" entries. Backslashes count as
// separators too, because they are on Windows and an entry written by a Windows
// zipper must not sneak a ".." past this check on Linux either. Same guarantee
// zip's enclosed_name() gives in api/archive.rs, without pulling that type in.
fn reject_unsafe_entry_name(name: &str) -> Result<(), String> {
    let reject = || Err(format!("Unsafe zip entry name, refusing to extract: {name}"));

    if name.is_empty() {
        return reject();
    }
    // Rooted: "/etc/x", "\\server\share", "C:\x", "C:/x".
    if name.starts_with('/') || name.starts_with('\\') {
        return reject();
    }
    // b':' is ASCII, so it can never be a UTF-8 continuation byte. Indexing
    // byte 1 is safe for any input.
    if name.len() >= 2 && name.as_bytes()[1] == b':' {
        return reject();
    }
    if name.split(['/', '\\']).any(|component| component == "..") {
        return reject();
    }

    Ok(())
}

fn find_entry<'a>(d: &'a ZipDownloader, entry_name: &str) -> Result<&'a ZipFileEntry, String> {
    reject_unsafe_entry_name(entry_name)?;

    d.manifest()
        .entries()
        .iter()
        .find(|e| e.name() == entry_name)
        .ok_or_else(|| format!("Zip entry not found: {entry_name}"))
}

pub async fn downloader_download_entry_by_name(
    d: RustAutoOpaque<DownloaderHandle>,
    entry_name: String,
    progress: Option<StreamSink<i32>>,
) -> Result<i32, String> {
    let handle = d.read().await;
    let inner: &ZipDownloader = &handle.inner;

    let entry = find_entry(inner, &entry_name)?;

    let token = {
        let mut guard = handle.cancel.lock().unwrap();
        *guard = CancellationToken::new();
        guard.clone()
    };

    let callback = progress.map(|sink| {
        Box::new(move |n: usize| {
            let _ = sink.add(n as i32);
        }) as Box<dyn Fn(usize) + Send + Sync>
    });

    tokio::select! {
        res = inner.download_single_file(entry, callback) => {
            let written = res.map_err(|e| e.to_string())?;
            Ok(written as i32)
        }
        _ = token.cancelled() => {
            Err("cancelled".to_string())
        }
    }
}

pub async fn downloader_cancel(d: RustAutoOpaque<DownloaderHandle>) {
    d.read().await.cancel.lock().unwrap().cancel();
}

pub async fn downloader_read_entry_bytes(
    d: RustAutoOpaque<DownloaderHandle>,
    entry_name: String,
    length: i64,
) -> Result<Vec<u8>, String> {
    let inner: &ZipDownloader = &d.read().await.inner;
    let entry = find_entry(inner, &entry_name)?;

    let bytes = inner
        .read_zip_entry_bytes(entry, length as u64)
        .await
        .map_err(|e| e.to_string())?;

    Ok(bytes.to_vec())
}

pub fn downloader_dispose(_d: RustAutoOpaque<DownloaderHandle>) {
}

#[cfg(test)]
mod tests {
    use super::reject_unsafe_entry_name;

    #[test]
    fn accepts_real_collection_entries() {
        assert!(reject_unsafe_entry_name("Foo.fbmod").is_ok());
        assert!(reject_unsafe_entry_name("My Collection.fbcollection").is_ok());
        assert!(reject_unsafe_entry_name("sub/dir/Foo.fbmod").is_ok());
        assert!(reject_unsafe_entry_name("sub/dir/").is_ok());
        assert!(reject_unsafe_entry_name("a..b.fbmod").is_ok());
    }

    #[test]
    fn rejects_traversal_and_rooted_names() {
        assert!(reject_unsafe_entry_name("../../.bashrc").is_err());
        assert!(reject_unsafe_entry_name("a/../../b").is_err());
        assert!(reject_unsafe_entry_name("/etc/passwd").is_err());
        assert!(reject_unsafe_entry_name("..\\..\\x").is_err());
        assert!(reject_unsafe_entry_name("C:\\Windows\\x").is_err());
        assert!(reject_unsafe_entry_name("").is_err());
    }
}