use std::collections::HashSet;
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::ptr::{NonNull, null_mut};

use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CAPTUREBLT, CreateCompatibleBitmap,
    CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, GetDIBits, HBITMAP, HDC,
    HGDIOBJ, ReleaseDC, SRCCOPY, SelectObject,
};
use windows_sys::Win32::Storage::Xps::PrintWindow;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetWindowRect, PRF_CHILDREN, PRF_CLIENT, PRF_ERASEBKGND, PRF_NONCLIENT, PRF_OWNED,
    SendMessageW, WM_PRINT,
};

const BMP_HEADER_BYTES: usize = 14;
const MAX_CAPTURE_BYTES: usize = 64 * 1024 * 1024;
const MINIMUM_DISTINCT_COLORS: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct CaptureMeasurement {
    pub(super) width: i32,
    pub(super) height: i32,
    pub(super) distinct_colors: usize,
    pub(super) used_window_dc_fallback: bool,
}

struct CaptureResources {
    screen_dc: HDC,
    memory_dc: HDC,
    bitmap: HBITMAP,
    previous: HGDIOBJ,
}

impl CaptureResources {
    fn create(width: i32, height: i32) -> io::Result<Self> {
        // SAFETY: null requests the screen DC; it is released exactly once by Drop.
        let screen_dc = unsafe { GetDC(null_mut()) };
        let screen_dc = NonNull::new(screen_dc)
            .ok_or_else(|| io::Error::other("could not acquire the visual-capture screen DC"))?
            .as_ptr();
        // SAFETY: screen_dc is live and compatible with the target window.
        let memory_dc = unsafe { CreateCompatibleDC(screen_dc) };
        let Some(memory_dc) = NonNull::new(memory_dc).map(NonNull::as_ptr) else {
            // SAFETY: screen_dc came from GetDC(null) and has not been released.
            unsafe { ReleaseDC(null_mut(), screen_dc) };
            return Err(io::Error::last_os_error());
        };
        // SAFETY: screen_dc is live and dimensions were validated as positive.
        let bitmap = unsafe { CreateCompatibleBitmap(screen_dc, width, height) };
        let Some(bitmap) = NonNull::new(bitmap).map(NonNull::as_ptr) else {
            // SAFETY: both resources are live and owned by this failed constructor.
            unsafe {
                DeleteDC(memory_dc);
                ReleaseDC(null_mut(), screen_dc);
            }
            return Err(io::Error::last_os_error());
        };
        // SAFETY: memory_dc and bitmap are live; the returned previous object is
        // restored before either resource is destroyed.
        let previous = unsafe { SelectObject(memory_dc, bitmap) };
        if previous.is_null() {
            // SAFETY: bitmap is not selected after a failed SelectObject call.
            unsafe {
                DeleteObject(bitmap);
                DeleteDC(memory_dc);
                ReleaseDC(null_mut(), screen_dc);
            }
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            screen_dc,
            memory_dc,
            bitmap,
            previous,
        })
    }

    fn deselect_bitmap(&mut self) -> io::Result<()> {
        if self.previous.is_null() {
            return Ok(());
        }
        // SAFETY: memory_dc currently contains this owner's bitmap and previous
        // is the exact live object returned by SelectObject during construction.
        if unsafe { SelectObject(self.memory_dc, self.previous) }.is_null() {
            return Err(io::Error::last_os_error());
        }
        self.previous = null_mut();
        Ok(())
    }

    fn select_bitmap(&mut self) -> io::Result<()> {
        if !self.previous.is_null() {
            return Ok(());
        }
        // SAFETY: bitmap and memory_dc are live and the bitmap is currently not
        // selected into another DC after deselect_bitmap returned successfully.
        let previous = unsafe { SelectObject(self.memory_dc, self.bitmap) };
        if previous.is_null() {
            return Err(io::Error::last_os_error());
        }
        self.previous = previous;
        Ok(())
    }
}

impl Drop for CaptureResources {
    fn drop(&mut self) {
        // SAFETY: this owner restores the exact prior object, then releases each
        // live GDI resource once in dependency order.
        unsafe {
            if !self.previous.is_null() {
                SelectObject(self.memory_dc, self.previous);
            }
            DeleteObject(self.bitmap);
            DeleteDC(self.memory_dc);
            ReleaseDC(null_mut(), self.screen_dc);
        }
    }
}

pub(super) fn write_window_bmp(window: HWND, output: &Path) -> io::Result<CaptureMeasurement> {
    if window.is_null() {
        return Err(io::Error::other("visual capture requires a live window"));
    }
    let mut rect = windows_sys::Win32::Foundation::RECT::default();
    // SAFETY: window is a live test-owned HWND and rect is writable storage.
    if unsafe { GetWindowRect(window, &mut rect) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let width = rect.right.saturating_sub(rect.left);
    let height = rect.bottom.saturating_sub(rect.top);
    if width <= 0 || height <= 0 {
        return Err(io::Error::other(
            "visual capture window has invalid geometry",
        ));
    }
    let width_usize = usize::try_from(width)
        .map_err(|_| io::Error::other("visual capture width is not representable"))?;
    let height_usize = usize::try_from(height)
        .map_err(|_| io::Error::other("visual capture height is not representable"))?;
    let pixel_bytes = width_usize
        .checked_mul(height_usize)
        .and_then(|pixels| pixels.checked_mul(4))
        .filter(|bytes| *bytes <= MAX_CAPTURE_BYTES)
        .ok_or_else(|| io::Error::other("visual capture exceeds the 64 MiB pixel budget"))?;
    let mut resources = CaptureResources::create(width, height)?;
    // SAFETY: the destination DC owns a compatible selected bitmap and the
    // synchronous PrintWindow call retains no caller pointers after returning.
    if unsafe { PrintWindow(window, resources.memory_dc, 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    // Wine and some native child configurations do not recurse through every
    // child after PrintWindow. WM_PRINT explicitly requests the same live window
    // plus its non-client, owned, and child surfaces into the selected bitmap.
    // SAFETY: window and destination DC remain live for this synchronous message;
    // lparam contains only documented pointer-free PRF flags.
    unsafe {
        SendMessageW(
            window,
            WM_PRINT,
            resources.memory_dc as usize,
            (PRF_CLIENT | PRF_NONCLIENT | PRF_CHILDREN | PRF_OWNED | PRF_ERASEBKGND) as isize,
        )
    };
    // GetDIBits requires that the source bitmap is not selected into any DC.
    resources.deselect_bitmap()?;

    let mut info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            biSizeImage: u32::try_from(pixel_bytes)
                .map_err(|_| io::Error::other("visual capture byte size is not representable"))?,
            ..BITMAPINFOHEADER::default()
        },
        ..BITMAPINFO::default()
    };
    let mut used_window_dc_fallback = false;
    let mut pixels = read_pixels(&resources, &mut info, height, pixel_bytes)?;
    let mut colors = distinct_colors(&pixels);
    if colors.len() < MINIMUM_DISTINCT_COLORS {
        used_window_dc_fallback = true;
        resources.select_bitmap()?;
        // SAFETY: window is live and this DC is released below after the bounded
        // synchronous fallback copy.
        let window_dc = unsafe { windows_sys::Win32::Graphics::Gdi::GetWindowDC(window) };
        let Some(window_dc) = NonNull::new(window_dc).map(NonNull::as_ptr) else {
            return Err(io::Error::last_os_error());
        };
        // SAFETY: source and destination DCs are live; both rectangles use the
        // validated target window dimensions and retain no pointers afterward.
        let copied = unsafe {
            BitBlt(
                resources.memory_dc,
                0,
                0,
                width,
                height,
                window_dc,
                0,
                0,
                SRCCOPY | CAPTUREBLT,
            )
        };
        // SAFETY: window_dc came from this exact live window and is released once.
        unsafe { ReleaseDC(window, window_dc) };
        if copied == 0 {
            return Err(io::Error::last_os_error());
        }
        resources.deselect_bitmap()?;
        pixels = read_pixels(&resources, &mut info, height, pixel_bytes)?;
        colors = distinct_colors(&pixels);
    }
    if colors.len() < MINIMUM_DISTINCT_COLORS {
        return Err(io::Error::other(format!(
            "visual capture is blank or nearly solid: {} distinct colors",
            colors.len()
        )));
    }

    let dib_bytes = size_of::<BITMAPINFOHEADER>();
    let file_bytes = BMP_HEADER_BYTES
        .checked_add(dib_bytes)
        .and_then(|header| header.checked_add(pixel_bytes))
        .ok_or_else(|| io::Error::other("visual capture BMP size overflowed"))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output)?;
    file.write_all(b"BM")?;
    file.write_all(
        &u32::try_from(file_bytes)
            .map_err(|_| io::Error::other("visual capture BMP is too large"))?
            .to_le_bytes(),
    )?;
    file.write_all(&[0_u8; 4])?;
    file.write_all(
        &u32::try_from(BMP_HEADER_BYTES + dib_bytes)
            .map_err(|_| io::Error::other("visual capture BMP offset overflowed"))?
            .to_le_bytes(),
    )?;
    file.write_all(&info.bmiHeader.biSize.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biWidth.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biHeight.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biPlanes.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biBitCount.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biCompression.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biSizeImage.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biXPelsPerMeter.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biYPelsPerMeter.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biClrUsed.to_le_bytes())?;
    file.write_all(&info.bmiHeader.biClrImportant.to_le_bytes())?;
    file.write_all(&pixels)?;
    file.flush()?;

    Ok(CaptureMeasurement {
        width,
        height,
        distinct_colors: colors.len(),
        used_window_dc_fallback,
    })
}

fn read_pixels(
    resources: &CaptureResources,
    info: &mut BITMAPINFO,
    height: i32,
    pixel_bytes: usize,
) -> io::Result<Vec<u8>> {
    let mut pixels = vec![0_u8; pixel_bytes];
    // SAFETY: bitmap is not selected into any DC; screen_dc and bitmap are live,
    // pixels matches the declared 32-bit DIB size, and info is writable.
    let copied = unsafe {
        GetDIBits(
            resources.screen_dc,
            resources.bitmap,
            0,
            u32::try_from(height)
                .map_err(|_| io::Error::other("visual capture height is not representable"))?,
            pixels.as_mut_ptr().cast(),
            info,
            DIB_RGB_COLORS,
        )
    };
    if copied != height {
        return Err(io::Error::other(format!(
            "visual capture copied {copied} scan lines, expected {height}"
        )));
    }
    Ok(pixels)
}

fn distinct_colors(pixels: &[u8]) -> HashSet<u32> {
    let mut colors = HashSet::with_capacity(MINIMUM_DISTINCT_COLORS + 1);
    for pixel in pixels.chunks_exact(4) {
        colors.insert(u32::from_le_bytes([pixel[0], pixel[1], pixel[2], 0]));
        if colors.len() > MINIMUM_DISTINCT_COLORS {
            break;
        }
    }
    colors
}

#[test]
#[ignore = "writes an external diagnostic visual gallery"]
fn write_appearance_dialog_visual_gallery() -> Result<(), Box<dyn std::error::Error>> {
    use std::fmt::Write as _;

    use crate::{AppThemeMode, ForcedColorsState, ResolvedTheme, UiAppearance};
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DestroyWindow, WS_OVERLAPPEDWINDOW,
    };

    use super::appearance_dialog::{create_appearance_dialog_window, visual_custom_colors_active};
    use super::text_io::wide;

    let output = std::env::var_os("DARKRENAMER_VISUAL_OUTPUT_DIR")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("DARKRENAMER_VISUAL_OUTPUT_DIR is required"))?;
    if !output.is_absolute() || !output.is_dir() {
        return Err(io::Error::other(
            "DARKRENAMER_VISUAL_OUTPUT_DIR must be an existing absolute directory",
        )
        .into());
    }
    let source_sha = std::env::var("DARKRENAMER_VISUAL_SOURCE_SHA")?;
    if source_sha.len() != 40
        || !source_sha
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(io::Error::other(
            "DARKRENAMER_VISUAL_SOURCE_SHA must be a lowercase full Git SHA",
        )
        .into());
    }
    let source_state = std::env::var("DARKRENAMER_VISUAL_SOURCE_STATE")?;
    if !matches!(source_state.as_str(), "clean" | "dirty") {
        return Err(
            io::Error::other("DARKRENAMER_VISUAL_SOURCE_STATE must be clean or dirty").into(),
        );
    }
    let runtime = std::env::var("DARKRENAMER_VISUAL_RUNTIME")?;
    if !matches!(runtime.as_str(), "wine" | "windows") {
        return Err(io::Error::other("DARKRENAMER_VISUAL_RUNTIME must be wine or windows").into());
    }
    let fixture_sha = std::env::var("DARKRENAMER_VISUAL_FIXTURE_SHA256")?;
    if fixture_sha.len() != 64
        || !fixture_sha
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(io::Error::other(
            "DARKRENAMER_VISUAL_FIXTURE_SHA256 must be a lowercase SHA-256",
        )
        .into());
    }
    // SAFETY: null requests the current process module.
    let instance = unsafe { GetModuleHandleW(null_mut()) };
    // SAFETY: the system STATIC class and current module remain live for this
    // hidden, test-owned dialog owner.
    let owner = unsafe {
        CreateWindowExW(
            0,
            wide("STATIC").as_ptr(),
            null_mut(),
            WS_OVERLAPPEDWINDOW,
            0,
            0,
            800,
            600,
            null_mut(),
            null_mut(),
            instance,
            null_mut(),
        )
    };
    if owner.is_null() {
        return Err(io::Error::last_os_error().into());
    }

    let result = (|| -> Result<
        Vec<(&'static str, CaptureMeasurement, bool)>,
        Box<dyn std::error::Error>,
    > {
        let mut captures = Vec::with_capacity(3);
        for (filename, theme, forced_colors, system_theme) in [
            (
                "appearance-light.bmp",
                AppThemeMode::Light,
                ForcedColorsState::Inactive,
                Some(ResolvedTheme::Light),
            ),
            (
                "appearance-dark.bmp",
                AppThemeMode::Dark,
                ForcedColorsState::Inactive,
                Some(ResolvedTheme::Dark),
            ),
            (
                "appearance-forced-colors-fallback.bmp",
                AppThemeMode::Dark,
                ForcedColorsState::ActiveOrUnknown,
                Some(ResolvedTheme::Dark),
            ),
        ] {
            let appearance = UiAppearance {
                theme,
                ..UiAppearance::default()
            };
            let dialog = create_appearance_dialog_window(
                owner,
                1,
                appearance,
                forced_colors,
                system_theme,
            )?;
            let custom_colors_active = visual_custom_colors_active(dialog)
                .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?;
            let capture = write_window_bmp(dialog, &output.join(filename));
            // SAFETY: dialog is the live test-owned window returned above and is
            // destroyed once after the synchronous capture attempt.
            unsafe { DestroyWindow(dialog) };
            captures.push((filename, capture?, custom_colors_active));
        }
        Ok(captures)
    })();
    // SAFETY: owner remains the live test-owned window after every dialog is closed.
    unsafe { DestroyWindow(owner) };
    let captures = result?;

    let mut manifest = String::from(
        "{\n  \"schema_version\": 1,\n  \"evidence_class\": \"diagnostic-fixture\",\n",
    );
    writeln!(&mut manifest, "  \"source_sha\": \"{source_sha}\",")?;
    writeln!(&mut manifest, "  \"source_state\": \"{source_state}\",")?;
    writeln!(&mut manifest, "  \"runtime\": \"{runtime}\",")?;
    writeln!(
        &mut manifest,
        "  \"fixture_executable_sha256\": \"{fixture_sha}\","
    )?;
    manifest.push_str(
        "  \"surface\": \"appearance-dialog\",\n  \"acceptance\": false,\n  \"captures\": [\n",
    );
    for (index, (filename, measurement, custom_colors_active)) in captures.iter().enumerate() {
        let comma = if index + 1 == captures.len() { "" } else { "," };
        let backend = if measurement.used_window_dc_fallback {
            "window-dc-bitblt-fallback"
        } else {
            "print-window"
        };
        writeln!(
            &mut manifest,
            "    {{\"filename\": \"{filename}\", \"width\": {}, \"height\": {}, \"distinct_colors_at_least\": {}, \"capture_backend\": \"{backend}\", \"custom_colors_active\": {custom_colors_active}}}{comma}",
            measurement.width, measurement.height, measurement.distinct_colors,
        )?;
    }
    manifest.push_str("  ]\n}\n");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output.join("visual-gallery.json"))?;
    file.write_all(manifest.as_bytes())?;
    file.flush()?;
    Ok(())
}
