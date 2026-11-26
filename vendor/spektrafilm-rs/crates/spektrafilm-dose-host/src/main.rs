use std::collections::HashMap;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, Result, bail};
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::{CompressionType, FilterType, PngEncoder};
use image::codecs::tiff::TiffEncoder;
use image::imageops::FilterType as ResizeFilter;
use image::{DynamicImage, ExtendedColorType, ImageDecoder, ImageEncoder, ImageReader};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use spektrafilm_core::params::RuntimeParams;
use spektrafilm_core::pipeline::Pipeline;
use spektrafilm_core::profile;
use spektrafilm_gpu::ComputeBackend;
use spektrafilm_math::colorspace;
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::{from_f32, from_f64, srgb_decode, srgb_encode};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
struct DoseParams {
    product_defaults: bool,
    preview_long_edge: u32,
    film_stock: String,
    print_stock: String,
    film_format_mm: f32,
    auto_exposure: bool,
    auto_exposure_method: String,
    exposure_compensation_ev: f32,
    print_exposure: f32,
    grain_active: bool,
    grain_sublayers_active: bool,
    grain_amount: f32,
    halation_active: bool,
    halation_amount: f64,
    halation_scatter_amount: f64,
    antihalation_removed: bool,
    halation_boost_ev: f32,
    dir_couplers_active: bool,
    dir_couplers_amount: f64,
    glare_active: bool,
    glare_amount: f64,
    y_filter_shift: f32,
    m_filter_shift: f32,
    filter_shift_scale: f32,
    c_filter_neutral: Option<f32>,
    m_filter_neutral: Option<f32>,
    y_filter_neutral: Option<f32>,
    scan_film: bool,
    extended_dynamic_range: bool,
    preflash_exposure: f32,
    contrast_mask_active: bool,
    contrast_mask_highlights: f32,
    contrast_mask_shadows: f32,
    contrast_mask_core: f32,
    contrast_mask_scale: f32,
    contrast_mask_scheme: String,
    overscan_active: bool,
    date_imprint_active: bool,
    scene_latitude_active: bool,
    scene_latitude_norm: String,
    scene_latitude_highlight_knee: f32,
    scene_latitude_highlight_room: f32,
    scene_latitude_shadow_knee: f32,
    scene_latitude_shadow_room: f32,
    scene_latitude_rolloff: f32,
    scene_latitude_max_lift: f32,
    scanner_unsharp_radius: f32,
    scanner_unsharp_amount: f32,
    digital_intermediate: bool,
    digital_intermediate_blue_compensation: bool,
    output_color_space: String,
    output_cctf_encoding: bool,
}

impl Default for DoseParams {
    fn default() -> Self {
        Self {
            product_defaults: true,
            preview_long_edge: 2560,
            film_stock: "kodak_portra_400".into(),
            print_stock: "kodak_portra_endura".into(),
            film_format_mm: 36.0,
            auto_exposure: true,
            auto_exposure_method: "balanced".into(),
            exposure_compensation_ev: 0.0,
            print_exposure: 1.0,
            grain_active: true,
            grain_sublayers_active: true,
            grain_amount: 1.0,
            halation_active: true,
            halation_amount: 1.0,
            halation_scatter_amount: 1.0,
            antihalation_removed: false,
            halation_boost_ev: 0.0,
            dir_couplers_active: true,
            dir_couplers_amount: 1.0,
            glare_active: true,
            glare_amount: 1.0,
            y_filter_shift: 0.0,
            m_filter_shift: 0.0,
            filter_shift_scale: 1.0,
            c_filter_neutral: None,
            m_filter_neutral: None,
            y_filter_neutral: None,
            scan_film: false,
            extended_dynamic_range: false,
            preflash_exposure: 0.0,
            contrast_mask_active: false,
            contrast_mask_highlights: 0.0,
            contrast_mask_shadows: 0.0,
            contrast_mask_core: 1.0,
            contrast_mask_scale: 0.03,
            contrast_mask_scheme: "gaussian".into(),
            overscan_active: false,
            date_imprint_active: false,
            scene_latitude_active: false,
            scene_latitude_norm: "power".into(),
            scene_latitude_highlight_knee: 2.0,
            scene_latitude_highlight_room: 0.0,
            scene_latitude_shadow_knee: -2.0,
            scene_latitude_shadow_room: 0.0,
            scene_latitude_rolloff: 2.0,
            scene_latitude_max_lift: 4.0,
            scanner_unsharp_radius: 0.7,
            scanner_unsharp_amount: 0.7,
            digital_intermediate: false,
            digital_intermediate_blue_compensation: false,
            output_color_space: "ProPhoto RGB".into(),
            output_cctf_encoding: true,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct GradeParams {
    temperature: f64,
    tint: f64,
    exposure: f64,
    contrast: f64,
    brightness: f64,
    highlights: f64,
    shadows: f64,
    black_point: f64,
    white_point: f64,
    saturation: f64,
    auto_fit_active: bool,
    auto_fit_ev: f64,
    auto_fit_saturation: f64,
}

struct Session {
    id: String,
    kind: String,
    full_width: u32,
    full_height: u32,
    full_source: ImageBuf,
    live_long_edge: u32,
    live_source: ImageBuf,
    params: DoseParams,
    pipeline: Option<Pipeline>,
    pipeline_key: String,
    cached_film_key: String,
    cached_film_buf: Option<ImageBuf>,
}

struct HostState {
    data_dir: PathBuf,
    backend: Box<dyn ComputeBackend>,
    srgb_icc: Vec<u8>,
    prophoto_icc: Vec<u8>,
    sessions: HashMap<String, Session>,
    next_session: u64,
}

fn is_raw_ext(ext: &str) -> bool {
    matches!(
        ext,
        "dng"
            | "cr2"
            | "cr3"
            | "nef"
            | "nrw"
            | "arw"
            | "srf"
            | "sr2"
            | "raf"
            | "orf"
            | "rw2"
            | "pef"
            | "srw"
            | "x3f"
            | "iiq"
            | "3fr"
            | "crw"
            | "rwl"
            | "mrw"
            | "mef"
            | "kdc"
            | "ari"
            | "bay"
            | "dcr"
            | "drf"
            | "erf"
            | "fff"
            | "k25"
            | "mos"
            | "ptx"
    )
}

fn load_raw(path: &Path) -> Result<ImageBuf> {
    use rawler::decode_file;
    use rawler::imgop::develop::{Intermediate, ProcessingStep, RawDevelop};
    let raw = decode_file(path).map_err(|e| anyhow::anyhow!("RAW decode failed: {e:?}"))?;
    let mut dev = RawDevelop::default();
    dev.steps.retain(|s| !matches!(s, ProcessingStep::SRgb));
    let intermediate = dev
        .develop_intermediate(&raw)
        .map_err(|e| anyhow::anyhow!("RAW develop failed: {e:?}"))?;
    match intermediate {
        Intermediate::Monochrome(pixels) => {
            let scalars = pixels
                .data
                .par_iter()
                .flat_map_iter(|&v| {
                    let s = from_f32(v.max(0.0));
                    [s, s, s]
                })
                .collect();
            Ok(ImageBuf::from_data(
                pixels.width as u32,
                pixels.height as u32,
                scalars,
            ))
        }
        Intermediate::ThreeColor(pixels) => {
            let scalars = pixels
                .data
                .par_iter()
                .flat_map_iter(|px| {
                    [
                        from_f32(px[0].max(0.0)),
                        from_f32(px[1].max(0.0)),
                        from_f32(px[2].max(0.0)),
                    ]
                })
                .collect();
            Ok(ImageBuf::from_data(
                pixels.width as u32,
                pixels.height as u32,
                scalars,
            ))
        }
        Intermediate::FourColor(pixels) => {
            let scalars = pixels
                .data
                .par_iter()
                .flat_map_iter(|px| {
                    [
                        from_f32(px[0].max(0.0)),
                        from_f32(px[1].max(0.0)),
                        from_f32(px[2].max(0.0)),
                    ]
                })
                .collect();
            Ok(ImageBuf::from_data(
                pixels.width as u32,
                pixels.height as u32,
                scalars,
            ))
        }
    }
}

fn load_image(path: &Path) -> Result<(ImageBuf, String)> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    if is_raw_ext(&ext) {
        return Ok((load_raw(path)?, "raw".into()));
    }
    let mut reader = ImageReader::open(path)
        .with_context(|| format!("opening image: {}", path.display()))?
        .with_guessed_format()
        .with_context(|| format!("detecting format: {}", path.display()))?;
    reader.no_limits();
    let mut decoder = reader
        .into_decoder()
        .with_context(|| format!("creating decoder: {}", path.display()))?;
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut dyn_img = DynamicImage::from_decoder(decoder)
        .with_context(|| format!("decoding image: {}", path.display()))?;
    dyn_img.apply_orientation(orientation);

    let is_linear_float = matches!(
        dyn_img,
        DynamicImage::ImageRgb32F(_) | DynamicImage::ImageRgba32F(_)
    );
    let rgb32f = dyn_img.to_rgb32f();
    let (w, h) = (rgb32f.width(), rgb32f.height());
    let raw = rgb32f.into_raw();
    let scalars: Vec<_> = if is_linear_float {
        raw.into_par_iter().map(from_f32).collect()
    } else {
        raw.into_par_iter()
            .map(|v| srgb_decode(from_f32(v.clamp(0.0, 1.0))))
            .collect()
    };
    let kind = match ext.as_str() {
        "tif" | "tiff" => "tiff",
        "png" => "png",
        _ => "jpeg",
    };
    Ok((ImageBuf::from_data(w, h, scalars), kind.into()))
}

fn probe_image(path: &Path) -> Result<(u32, u32, String)> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    if is_raw_ext(&ext) {
        let img = load_raw(path)?;
        return Ok((img.width, img.height, "raw".into()));
    }
    let reader = ImageReader::open(path)
        .with_context(|| format!("opening image: {}", path.display()))?
        .with_guessed_format()
        .with_context(|| format!("detecting format: {}", path.display()))?;
    let mut decoder = reader.into_decoder()?;
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let (mut w, mut h) = decoder.dimensions();
    use image::metadata::Orientation::*;
    if matches!(
        orientation,
        Rotate90 | Rotate270 | Rotate90FlipH | Rotate270FlipH
    ) {
        std::mem::swap(&mut w, &mut h);
    }
    let kind = match ext.as_str() {
        "tif" | "tiff" => "tiff",
        "png" => "png",
        _ => "jpeg",
    };
    Ok((w, h, kind.into()))
}

fn resize_long_edge(src: &ImageBuf, long_edge: u32) -> ImageBuf {
    let max_dim = src.width.max(src.height);
    if long_edge == 0 || max_dim <= long_edge {
        return src.clone();
    }
    let scale = long_edge as f64 / max_dim as f64;
    let new_w = ((src.width as f64 * scale).round() as u32).max(1);
    let new_h = ((src.height as f64 * scale).round() as u32).max(1);
    let f32_buf: Vec<f32> = src.data.iter().map(|&v| v as f32).collect();
    let img = image::ImageBuffer::<image::Rgb<f32>, _>::from_raw(src.width, src.height, f32_buf)
        .expect("ImageBuf dims match data");
    let resized = image::imageops::resize(&img, new_w, new_h, ResizeFilter::CatmullRom);
    let data = resized.into_raw().into_iter().map(from_f32).collect();
    ImageBuf::from_data(new_w, new_h, data)
}

fn map_auto_exposure_method(m: &str) -> String {
    match m {
        "balanced" => "center_weighted".into(),
        "center" => "partial".into(),
        "protect_highlights" => "highlight_weighted".into(),
        "protect_shadows" => "average".into(),
        other => other.into(),
    }
}

fn build_runtime_params(d: &DoseParams, force_prophoto_linear: bool) -> RuntimeParams {
    let mut p = RuntimeParams::default();
    p.io.input_color_space = "sRGB".into();
    p.io.input_cctf_decoding = false;
    p.io.scan_film = d.scan_film;
    if force_prophoto_linear {
        p.io.output_color_space = "ProPhoto RGB".into();
        p.io.output_cctf_encoding = false;
    } else {
        p.io.output_color_space = d.output_color_space.clone();
        p.io.output_cctf_encoding = d.output_cctf_encoding;
    }

    p.camera.film_format_mm = d.film_format_mm.clamp(4.0, 200.0);
    p.camera.auto_exposure = d.auto_exposure;
    p.camera.auto_exposure_method = map_auto_exposure_method(&d.auto_exposure_method);
    p.camera.exposure_compensation_ev = d.exposure_compensation_ev;

    p.enlarger.print_exposure = d.print_exposure.clamp(0.01, 100.0);
    p.enlarger.y_filter_shift = d.y_filter_shift * d.filter_shift_scale;
    p.enlarger.m_filter_shift = d.m_filter_shift * d.filter_shift_scale;
    p.enlarger.preflash_exposure = d.preflash_exposure.clamp(0.0, 1.0);
    if let (Some(c), Some(m), Some(y)) = (d.c_filter_neutral, d.m_filter_neutral, d.y_filter_neutral) {
        p.enlarger.c_filter_neutral = c;
        p.enlarger.m_filter_neutral = m;
        p.enlarger.y_filter_neutral = y;
        p.settings.neutral_print_filters_from_database = false;
    } else {
        p.settings.neutral_print_filters_from_database = true;
    }

    let grain_amt = d.grain_amount.max(0.0) as f64;
    p.film_render.grain.active = d.grain_active && grain_amt > 0.0;
    p.film_render.grain.sublayers_active = d.grain_sublayers_active;
    // Scale particle area quadratically so visual grain sigma scales linearly with grain_amount.
    p.film_render.grain.agx_particle_area_um2 = 0.2 * (grain_amt * grain_amt).clamp(0.0025, 4.0);

    let hal_amt = d.halation_amount.max(0.0);
    let scat_amt = d.halation_scatter_amount.max(0.0);
    p.film_render.halation.active = d.halation_active && (hal_amt > 0.0 || scat_amt > 0.0);
    p.film_render.halation.halation_amount = hal_amt;
    p.film_render.halation.scatter_amount = scat_amt;
    p.film_render.halation.boost_ev = d.halation_boost_ev;
    if d.antihalation_removed {
        p.film_render.halation.halation_strength = [0.20, 0.06, 0.02];
    }

    p.film_render.dir_couplers.active = d.dir_couplers_active && d.dir_couplers_amount > 0.0;
    p.film_render.dir_couplers.amount = d.dir_couplers_amount.clamp(0.0, 2.0);

    let glare_active = d.glare_active && d.glare_amount > 0.0;
    let glare_pct = (0.03 * d.glare_amount.max(0.0)) as f32;
    p.film_render.glare.active = glare_active;
    p.film_render.glare.percent = glare_pct;
    p.print_render.glare.active = glare_active;
    p.print_render.glare.percent = glare_pct;

    p.scanner.unsharp_mask = [
        d.scanner_unsharp_radius.max(0.0),
        d.scanner_unsharp_amount.max(0.0),
    ];

    p.settings.use_cat16 = true;
    p
}

fn scene_latitude_dep(d: f64, h: f64, m: f64) -> f64 {
    if !(d > 0.0) {
        return 0.0;
    }
    if (m - 2.0).abs() < 1e-9 {
        let r = (h * h + d * d).sqrt();
        -(d * d * d) / (r * (h + r))
    } else if (m - 1.0).abs() < 1e-9 {
        -(d * d) / (h + d)
    } else {
        d * (h / (h.powf(m) + d.powf(m)).powf(1.0 / m) - 1.0)
    }
}

fn apply_scene_latitude(src: &ImageBuf, d: &DoseParams) -> ImageBuf {
    if !d.scene_latitude_active {
        return src.clone();
    }
    let kh = d.scene_latitude_highlight_knee as f64;
    let hh = d.scene_latitude_highlight_room as f64;
    let ks = d.scene_latitude_shadow_knee as f64;
    let hs = d.scene_latitude_shadow_room as f64;
    let m = d.scene_latitude_rolloff as f64;
    let max_lift = d.scene_latitude_max_lift as f64;
    let mid = 0.184f64;
    let min_x = mid * (-24.0f64).exp2();
    let k_min = (-30.0f64).exp2();
    let k_max = (30.0f64).exp2();
    let norm_mode = match d.scene_latitude_norm.as_str() {
        "y" => 1u8,
        "max" => 2u8,
        _ => 0u8,
    };

    let mut out = src.clone();
    out.data.par_chunks_exact_mut(3).for_each(|px| {
        let r = px[0] as f64;
        let g = px[1] as f64;
        let b = px[2] as f64;
        let cr = r.max(0.0);
        let cg = g.max(0.0);
        let cb = b.max(0.0);
        let x = match norm_mode {
            1 => 0.2126 * cr + 0.7152 * cg + 0.0722 * cb,
            2 => cr.max(cg).max(cb),
            _ => {
                let s = cr * cr + cg * cg + cb * cb;
                if s > 0.0 {
                    (cr * cr * cr + cg * cg * cg + cb * cb * cb) / s
                } else {
                    0.0
                }
            }
        };
        let mut k = 1.0;
        if x > 0.0 && x.is_finite() {
            let e = (x.max(min_x) / mid).log2().clamp(-24.0, 24.0);
            let mut delta = 0.0;
            if hh > 0.0 && e > kh {
                delta = scene_latitude_dep(e - kh, hh, m);
            } else if hs > 0.0 && e < ks {
                delta = -scene_latitude_dep(ks - e, hs, m);
            }
            if delta > 0.0 && max_lift > 0.0 {
                delta = delta * max_lift / (max_lift * max_lift + delta * delta).sqrt();
            }
            k = delta.exp2().clamp(k_min, k_max);
        }
        px[0] = from_f64(r * k);
        px[1] = from_f64(g * k);
        px[2] = from_f64(b * k);
    });
    out
}

#[inline]
fn romm_encode(v: f64) -> f64 {
    let x = v.clamp(0.0, 1.0);
    if x < 1.0 / 512.0 {
        16.0 * x
    } else {
        x.powf(1.0 / 1.8)
    }
}

#[inline]
fn romm_decode(v: f64) -> f64 {
    let x = v.clamp(0.0, 1.0);
    if x < 16.0 / 512.0 {
        x / 16.0
    } else {
        x.powf(1.8)
    }
}

fn auto_fit_correct_linear(r: f64, g: f64, b: f64, ev: f64, sat: f64) -> [f64; 3] {
    if ev == 0.0 && sat == 1.0 {
        return [r, g, b];
    }
    let y = 0.2880402 * r + 0.7118741 * g + 0.0000857 * b;
    let gain = ev.exp2();
    let y_new = y * gain / (1.0 + (gain - 1.0) * y);
    let ratio = y_new / y.max(1e-8);
    let d0 = (r * ratio - y_new) * sat;
    let d1 = (g * ratio - y_new) * sat;
    let d2 = (b * ratio - y_new) * sat;
    let bound = |v: f64, d: f64| -> f64 {
        if d > 0.0 {
            (1.0 - v) / d
        } else if d < 0.0 {
            -v / d
        } else {
            1.0
        }
    };
    let scale = 1.0f64
        .min(bound(y_new, d0))
        .min(bound(y_new, d1))
        .min(bound(y_new, d2))
        .clamp(0.0, 1.0);
    [
        (y_new + d0 * scale).clamp(0.0, 1.0),
        (y_new + d1 * scale).clamp(0.0, 1.0),
        (y_new + d2 * scale).clamp(0.0, 1.0),
    ]
}

fn apply_layer2_prophoto_encoded(linear_prophoto: &ImageBuf, g: &GradeParams) -> Vec<f64> {
    let mid = 0.3857f64;
    let mut out = vec![0.0f64; linear_prophoto.data.len()];
    let fit_active = g.auto_fit_active && g.auto_fit_ev != 0.0;
    let fit_sat = if g.auto_fit_saturation > 0.0 {
        g.auto_fit_saturation
    } else {
        1.0
    };
    let temp_gains = [
        1.0 + 0.18 * g.temperature,
        1.0 - 0.12 * g.tint,
        1.0 - 0.18 * g.temperature,
    ];
    let bp = g.black_point;
    let span = (1.0 - bp - g.white_point).max(0.05);

    out.par_chunks_exact_mut(3)
        .zip(linear_prophoto.data.par_chunks_exact(3))
        .for_each(|(dst, src)| {
            let mut r = src[0] as f64;
            let mut gr = src[1] as f64;
            let mut b = src[2] as f64;
            if fit_active {
                let fitted = auto_fit_correct_linear(r, gr, b, g.auto_fit_ev, fit_sat);
                r = fitted[0];
                gr = fitted[1];
                b = fitted[2];
            }
            let mut c = [romm_encode(r), romm_encode(gr), romm_encode(b)];
            for k in 0..3 {
                c[k] *= temp_gains[k];
            }
            if g.exposure != 0.0 {
                let gain = g.exposure.exp2();
                for k in 0..3 {
                    c[k] = (c[k].max(0.0).powf(2.2) * gain).powf(1.0 / 2.2);
                }
            }
            if g.contrast != 0.0 {
                let factor = 1.0 + g.contrast * 1.2;
                for k in 0..3 {
                    c[k] = (c[k] - mid) * factor + mid;
                }
            }
            if g.brightness != 0.0 {
                let exp = 1.0 / (1.0 + g.brightness * 0.8);
                for k in 0..3 {
                    c[k] = c[k].max(0.0).powf(exp);
                }
            }
            let luma = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
            let position = if luma <= mid {
                0.5 * luma / mid
            } else {
                0.5 + 0.5 * (luma - mid) / (1.0 - mid)
            };
            if g.shadows != 0.0 {
                let factor = g.shadows * 0.25 * (1.0 - position).powi(2);
                for k in 0..3 {
                    c[k] += factor * (1.0 - c[k]);
                }
            }
            if g.highlights != 0.0 {
                let w = g.highlights * 0.25 * position.powi(2);
                for k in 0..3 {
                    c[k] += w * if g.highlights > 0.0 { 1.0 - c[k] } else { c[k] };
                }
            }
            if bp != 0.0 || g.white_point != 0.0 {
                for k in 0..3 {
                    c[k] = (c[k] - bp) / span;
                }
            }
            if g.saturation != 0.0 {
                let l = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
                let s = 1.0 + g.saturation;
                for k in 0..3 {
                    c[k] = l + (c[k] - l) * s;
                }
            }
            dst[0] = c[0].clamp(0.0, 1.0);
            dst[1] = c[1].clamp(0.0, 1.0);
            dst[2] = c[2].clamp(0.0, 1.0);
        });
    out
}

fn prophoto_encoded_to_srgb_u8(encoded_prophoto: &[f64]) -> Vec<u8> {
    let p2x = colorspace::PROPHOTO_TO_XYZ_F64;
    let x2s = colorspace::XYZ_TO_SRGB_F64;
    // D50 -> D65 Bradford adaptation (ProPhoto white is D50, sRGB white is D65).
    let d50 = [0.9642956764295677, 1.0, 0.8251046025104602];
    let d65 = [0.95047, 1.0, 1.08883];
    let adapt = colorspace::chromatic_adaptation_matrix_f64(d50, d65);
    let mut m = [[0.0f64; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            let mut ax = [0.0f64; 3];
            for k in 0..3 {
                ax[k] = adapt[k][0] * p2x[0][j] + adapt[k][1] * p2x[1][j] + adapt[k][2] * p2x[2][j];
            }
            m[i][j] = x2s[i][0] * ax[0] + x2s[i][1] * ax[1] + x2s[i][2] * ax[2];
        }
    }
    let n_px = encoded_prophoto.len() / 3;
    let mut out = vec![0u8; n_px * 3];
    out.par_chunks_exact_mut(3)
        .zip(encoded_prophoto.par_chunks_exact(3))
        .for_each(|(dst, src)| {
            let r = romm_decode(src[0]);
            let g = romm_decode(src[1]);
            let b = romm_decode(src[2]);
            let sr = (m[0][0] * r + m[0][1] * g + m[0][2] * b).clamp(0.0, 1.0);
            let sg = (m[1][0] * r + m[1][1] * g + m[1][2] * b).clamp(0.0, 1.0);
            let sb = (m[2][0] * r + m[2][1] * g + m[2][2] * b).clamp(0.0, 1.0);
            let er = srgb_encode(from_f64(sr)) as f64;
            let eg = srgb_encode(from_f64(sg)) as f64;
            let eb = srgb_encode(from_f64(sb)) as f64;
            dst[0] = (er.clamp(0.0, 1.0) * 255.0).round_ties_even() as u8;
            dst[1] = (eg.clamp(0.0, 1.0) * 255.0).round_ties_even() as u8;
            dst[2] = (eb.clamp(0.0, 1.0) * 255.0).round_ties_even() as u8;
        });
    out
}

fn prophoto_encoded_to_rgba8(encoded_prophoto: &[f64]) -> Vec<u8> {
    let rgb = prophoto_encoded_to_srgb_u8(encoded_prophoto);
    let mut rgba = Vec::with_capacity((rgb.len() / 3) * 4);
    for px in rgb.chunks_exact(3) {
        rgba.extend_from_slice(&[px[0], px[1], px[2], 255]);
    }
    rgba
}

fn encode_png16_prophoto(encoded_prophoto: &[f64], w: u32, h: u32, icc: &[u8]) -> Result<Vec<u8>> {
    let u16_bytes: Vec<u8> = encoded_prophoto
        .par_iter()
        .flat_map_iter(|&v| {
            let q = (v.clamp(0.0, 1.0) * 65535.0).round_ties_even() as u16;
            q.to_ne_bytes()
        })
        .collect();
    let mut out = Vec::with_capacity((w * h * 6) as usize);
    let mut encoder = PngEncoder::new_with_quality(&mut out, CompressionType::Fast, FilterType::Adaptive);
    if !icc.is_empty() {
        let _ = encoder.set_icc_profile(icc.to_vec());
    }
    encoder.write_image(&u16_bytes, w, h, ExtendedColorType::Rgb16)?;
    Ok(out)
}

fn encode_rgba16_prophoto(encoded_prophoto: &[f64]) -> Vec<u8> {
    let mut out = Vec::with_capacity((encoded_prophoto.len() / 3) * 8);
    for px in encoded_prophoto.chunks_exact(3) {
        let r = (px[0].clamp(0.0, 1.0) * 65535.0).round_ties_even() as u16;
        let g = (px[1].clamp(0.0, 1.0) * 65535.0).round_ties_even() as u16;
        let b = (px[2].clamp(0.0, 1.0) * 65535.0).round_ties_even() as u16;
        out.extend_from_slice(&r.to_le_bytes());
        out.extend_from_slice(&g.to_le_bytes());
        out.extend_from_slice(&b.to_le_bytes());
        out.extend_from_slice(&65535u16.to_le_bytes());
    }
    out
}

fn ensure_pipeline_and_film(
    state: &mut HostState,
    sid: &str,
    source_buf: &ImageBuf,
    force_prophoto_linear: bool,
    tag: &str,
) -> Result<ImageBuf> {
    let session = state
        .sessions
        .get_mut(sid)
        .ok_or_else(|| anyhow::anyhow!("session not found: {sid}"))?;
    let rt = build_runtime_params(&session.params, force_prophoto_linear);
    let pkey = format!(
        "{}|{}|{}|{:.5}|{:.4}|{:.4}|{:.4}|{:?}|{:?}|{:?}|{}|{}|{}|{}",
        session.params.film_stock,
        session.params.print_stock,
        session.params.scan_film,
        session.params.exposure_compensation_ev,
        session.params.y_filter_shift,
        session.params.m_filter_shift,
        session.params.preflash_exposure,
        session.params.c_filter_neutral,
        session.params.m_filter_neutral,
        session.params.y_filter_neutral.map(|v| format!("{v:.3}")).unwrap_or_default(),
        rt.io.output_color_space,
        rt.io.output_cctf_encoding,
        session.params.dir_couplers_active,
        session.params.dir_couplers_amount,
    );
    if session.pipeline.is_none() || session.pipeline_key != pkey {
        let film = profile::load_profile_by_name(&state.data_dir, &session.params.film_stock)
            .map_err(|e| anyhow::anyhow!("loading film {}: {e}", session.params.film_stock))?;
        let print_name = if session.params.scan_film {
            session.params.film_stock.clone()
        } else {
            session.params.print_stock.clone()
        };
        let print = profile::load_profile_by_name(&state.data_dir, &print_name)
            .map_err(|e| anyhow::anyhow!("loading print {print_name}: {e}"))?;
        let pipe = Pipeline::new_with_spectral(film, print, rt, &state.data_dir)
            .map_err(|e| anyhow::anyhow!("pipeline calibration failed: {e}"))?;
        session.pipeline = Some(pipe);
        session.pipeline_key = pkey;
        session.cached_film_buf = None;
    } else if let Some(pipe) = session.pipeline.take() {
        session.pipeline = Some(pipe.with_params(rt));
    }

    let fkey = format!("{tag}:{}", serde_json::to_string(&session.params)?);
    if session.cached_film_key == fkey {
        if let Some(ref cached) = session.cached_film_buf {
            return Ok(cached.clone());
        }
    }

    let exposed_input = apply_scene_latitude(source_buf, &session.params);
    let pipe = session.pipeline.as_ref().expect("pipeline initialized");
    let out = pipe.process(exposed_input, state.backend.as_ref());
    session.cached_film_key = fkey;
    session.cached_film_buf = Some(out.clone());
    Ok(out)
}

fn merge_dose_params(p: &mut DoseParams, delta: &Value) -> Result<()> {
    let mut val = serde_json::to_value(&*p)?;
    if let (Some(dst), Some(src)) = (val.as_object_mut(), delta.as_object()) {
        if src.contains_key("film_stock") || src.contains_key("print_stock") {
            for k in ["c_filter_neutral", "m_filter_neutral", "y_filter_neutral"] {
                if !src.contains_key(k) {
                    dst.insert(k.to_string(), Value::Null);
                }
            }
        }
        for (k, v) in src {
            dst.insert(k.clone(), v.clone());
        }
    }
    *p = serde_json::from_value(val)?;
    Ok(())
}

fn handle_request(state: &mut HostState, method: &str, params: Value) -> Result<(Value, Vec<u8>)> {
    match method {
        "hello" => {
            let is_gpu = state.backend.is_gpu();
            let bname = state.backend.name().to_string();
            Ok((
                json!({
                    "protocol": 1,
                    "host_version": "spektrafilm-rs-0.1.2/dose",
                    "build_info": "spektrafilm-rs 0.1.2 (spektrafilm 0.3.4 parity)",
                    "backend": {
                        "api": if is_gpu { "wgpu" } else { "cpu" },
                        "available": true,
                        "device_name": bname,
                        "render_core": if is_gpu { "native-vulkan" } else { "cpu-rayon" },
                        "math_mode": if is_gpu { "wgpu f32 resident / spektrafilm 0.3.4" } else { "cpu rayon / spektrafilm 0.3.4" },
                        "engine": "spektrafilm-rs"
                    },
                    "resources_dir": state.data_dir.display().to_string(),
                    "methods": ["hello","ping","shutdown","probe","open","set_params","render","export_image","decode_raw","close"]
                }),
                Vec::new(),
            ))
        }
        "ping" => Ok((json!({}), Vec::new())),
        "probe" => {
            let p = params["path"].as_str().context("missing path")?;
            let (w, h, kind) = probe_image(Path::new(p))?;
            Ok((json!({ "width": w, "height": h, "kind": kind, "metadata": {} }), Vec::new()))
        }
        "decode_raw" => {
            let p = params["path"].as_str().context("missing path")?;
            let buf = load_raw(Path::new(p))?;
            let (w, h) = (buf.width, buf.height);
            let mut rgba = vec![255u8; (w * h * 4) as usize];
            rgba.par_chunks_exact_mut(4)
                .zip(buf.data.par_chunks_exact(3))
                .for_each(|(dst, src)| {
                    dst[0] = (srgb_encode(src[0].max(from_f64(0.0)).min(from_f64(1.0))) as f64 * 255.0).round_ties_even() as u8;
                    dst[1] = (srgb_encode(src[1].max(from_f64(0.0)).min(from_f64(1.0))) as f64 * 255.0).round_ties_even() as u8;
                    dst[2] = (srgb_encode(src[2].max(from_f64(0.0)).min(from_f64(1.0))) as f64 * 255.0).round_ties_even() as u8;
                    dst[3] = 255;
                });
            Ok((
                json!({
                    "image": { "width": w, "height": h, "format": "rgba8", "color_space": "sRGB", "row_bytes": w * 4 }
                }),
                rgba,
            ))
        }
        "open" => {
            let t0 = Instant::now();
            let path_str = params["path"].as_str().context("missing path")?;
            let mut dp = DoseParams::default();
            if let Some(p_val) = params.get("params") {
                merge_dose_params(&mut dp, p_val)?;
            }
            let (full_source, kind) = load_image(Path::new(path_str))?;
            let decode_ms = t0.elapsed().as_secs_f64() * 1000.0;
            let (w, h) = (full_source.width, full_source.height);
            let live_edge = dp.preview_long_edge.clamp(320, 8192);
            let live_source = resize_long_edge(&full_source, live_edge);

            state.next_session += 1;
            let sid = format!("s{}", state.next_session);
            let session = Session {
                id: sid.clone(),
                kind: kind.clone(),
                full_width: w,
                full_height: h,
                full_source: full_source.clone(),
                live_long_edge: live_edge,
                live_source,
                params: dp.clone(),
                pipeline: None,
                pipeline_key: String::new(),
                cached_film_key: String::new(),
                cached_film_buf: None,
            };
            state.sessions.insert(sid.clone(), session);
            // Validate film/print & pre-calibrate immediately so invalid profiles fail on open.
            let live_buf = state.sessions[&sid].live_source.clone();
            let force_prophoto = dp.output_color_space == "ProPhoto RGB";
            ensure_pipeline_and_film(state, &sid, &live_buf, force_prophoto, &format!("live:{live_edge}"))?;
            let open_ms = t0.elapsed().as_secs_f64() * 1000.0;
            Ok((
                json!({
                    "session": sid,
                    "width": w,
                    "height": h,
                    "kind": kind,
                    "output_color_space": dp.output_color_space,
                    "detected_input": { "input_color_space": "sRGB", "input_cctf_decoding": false },
                    "params": serde_json::to_value(&dp)?,
                    "timings_ms": { "decode": decode_ms, "open": open_ms }
                }),
                Vec::new(),
            ))
        }
        "set_params" => {
            let sid = params["session"].as_str().context("missing session")?;
            let delta = &params["delta"];
            let session = state
                .sessions
                .get_mut(sid)
                .ok_or_else(|| anyhow::anyhow!("session not found: {sid}"))?;
            merge_dose_params(&mut session.params, delta)?;
            let wanted_edge = session.params.preview_long_edge.clamp(320, 8192);
            if wanted_edge != session.live_long_edge {
                session.live_source = resize_long_edge(&session.full_source, wanted_edge);
                session.live_long_edge = wanted_edge;
                session.cached_film_buf = None;
            }
            let out_params = serde_json::to_value(&session.params)?;
            Ok((json!({ "params": out_params }), Vec::new()))
        }
        "render" => {
            let sid = params["session"].as_str().context("missing session")?;
            let tier = params["tier"].as_str().unwrap_or("live");
            let format = params["format"].as_str().unwrap_or("rgba8");
            let grade: GradeParams = params
                .get("grade")
                .map(|g| serde_json::from_value(g.clone()))
                .transpose()?
                .unwrap_or_default();

            let (source_buf, edge_tag, out_cs) = {
                let s = state
                    .sessions
                    .get(sid)
                    .ok_or_else(|| anyhow::anyhow!("session not found: {sid}"))?;
                if tier == "full" {
                    (s.full_source.clone(), "full".to_string(), s.params.output_color_space.clone())
                } else {
                    (s.live_source.clone(), format!("live:{}", s.live_long_edge), s.params.output_color_space.clone())
                }
            };

            let t0 = Instant::now();
            let force_prophoto = out_cs == "ProPhoto RGB";
            let film_buf = ensure_pipeline_and_film(state, sid, &source_buf, force_prophoto, &edge_tag)?;
            let engine_ms = t0.elapsed().as_secs_f64() * 1000.0;
            let (w, h) = (film_buf.width, film_buf.height);

            let t1 = Instant::now();
            let (payload, actual_cs) = if force_prophoto {
                let graded = apply_layer2_prophoto_encoded(&film_buf, &grade);
                match format {
                    "png16" => (
                        encode_png16_prophoto(&graded, w, h, &state.prophoto_icc)?,
                        "ProPhoto RGB",
                    ),
                    "rgba16" => (encode_rgba16_prophoto(&graded), "ProPhoto RGB"),
                    _ => (prophoto_encoded_to_rgba8(&graded), "sRGB"),
                }
            } else {
                // Legacy v1 sRGB path (e.g. cleanAdjustments({engine: 'spectral'}))
                let mut rgba = Vec::with_capacity((w * h * 4) as usize);
                for px in film_buf.data.chunks_exact(3) {
                    rgba.push((px[0].clamp(from_f64(0.0), from_f64(1.0)) as f64 * 255.0).round_ties_even() as u8);
                    rgba.push((px[1].clamp(from_f64(0.0), from_f64(1.0)) as f64 * 255.0).round_ties_even() as u8);
                    rgba.push((px[2].clamp(from_f64(0.0), from_f64(1.0)) as f64 * 255.0).round_ties_even() as u8);
                    rgba.push(255);
                }
                (rgba, "sRGB")
            };
            let transform_ms = t1.elapsed().as_secs_f64() * 1000.0;
            let total_ms = t0.elapsed().as_secs_f64() * 1000.0;

            Ok((
                json!({
                    "image": {
                        "width": w,
                        "height": h,
                        "format": format,
                        "color_space": actual_cs,
                        "row_bytes": if format == "rgba8" { w * 4 } else { 0 }
                    },
                    "tier": tier,
                    "reprinted": false,
                    "timings_ms": { "engine": engine_ms, "render": engine_ms, "transform": transform_ms, "total": total_ms }
                }),
                payload,
            ))
        }
        "export_image" => {
            let sid = params["session"].as_str().context("missing session")?;
            let out_path = PathBuf::from(params["path"].as_str().context("missing path")?);
            let format = params["format"].as_str().unwrap_or("jpeg");
            let long_edge = params["long_edge"].as_u64().unwrap_or(0) as u32;
            let quality = params["quality"].as_u64().unwrap_or(96).clamp(1, 100) as u8;
            let overwrite = params["overwrite"].as_bool().unwrap_or(false);
            let grade: GradeParams = params
                .get("grade")
                .map(|g| serde_json::from_value(g.clone()))
                .transpose()?
                .unwrap_or_default();

            if !overwrite && out_path.exists() {
                bail!("destination already exists: {}", out_path.display());
            }
            if let Some(parent) = out_path.parent() {
                std::fs::create_dir_all(parent)?;
            }

            let source_buf = {
                let s = state
                    .sessions
                    .get(sid)
                    .ok_or_else(|| anyhow::anyhow!("session not found: {sid}"))?;
                resize_long_edge(&s.full_source, long_edge)
            };
            let tag = format!("export:{long_edge}");
            let film_buf = ensure_pipeline_and_film(state, sid, &source_buf, true, &tag)?;
            let (w, h) = (film_buf.width, film_buf.height);
            let graded = apply_layer2_prophoto_encoded(&film_buf, &grade);

            let tmp_path = out_path.with_extension(format!(
                "{}.partial-{}",
                out_path.extension().and_then(|e| e.to_str()).unwrap_or("tmp"),
                std::process::id()
            ));

            let write_res: Result<String> = (|| {
                let f = std::fs::File::create(&tmp_path)?;
                let mut writer = BufWriter::new(f);
                match format {
                    "tiff16" | "tiff" => {
                        let u16_bytes: Vec<u8> = graded
                            .par_iter()
                            .flat_map_iter(|&v| {
                                let q = (v.clamp(0.0, 1.0) * 65535.0).round_ties_even() as u16;
                                q.to_ne_bytes()
                            })
                            .collect();
                        let mut enc = TiffEncoder::new(&mut writer);
                        if !state.prophoto_icc.is_empty() {
                            let _ = enc.set_icc_profile(state.prophoto_icc.clone());
                        }
                        enc.write_image(&u16_bytes, w, h, ExtendedColorType::Rgb16)?;
                        writer.flush()?;
                        Ok("ProPhoto RGB".into())
                    }
                    "png" => {
                        let srgb_u8 = prophoto_encoded_to_srgb_u8(&graded);
                        let mut enc = PngEncoder::new(&mut writer);
                        if !state.srgb_icc.is_empty() {
                            let _ = enc.set_icc_profile(state.srgb_icc.clone());
                        }
                        enc.write_image(&srgb_u8, w, h, ExtendedColorType::Rgb8)?;
                        writer.flush()?;
                        Ok("sRGB".into())
                    }
                    _ => {
                        let srgb_u8 = prophoto_encoded_to_srgb_u8(&graded);
                        let mut enc = JpegEncoder::new_with_quality(&mut writer, quality);
                        if !state.srgb_icc.is_empty() {
                            let _ = enc.set_icc_profile(state.srgb_icc.clone());
                        }
                        enc.write_image(&srgb_u8, w, h, ExtendedColorType::Rgb8)?;
                        writer.flush()?;
                        Ok("sRGB".into())
                    }
                }
            })();

            let written_cs = match write_res {
                Ok(cs) => cs,
                Err(e) => {
                    let _ = std::fs::remove_file(&tmp_path);
                    return Err(e);
                }
            };
            std::fs::rename(&tmp_path, &out_path)?;
            let bytes = std::fs::metadata(&out_path).map(|m| m.len()).unwrap_or(0);

            Ok((
                json!({
                    "path": out_path.display().to_string(),
                    "width": w,
                    "height": h,
                    "bytes": bytes,
                    "color_space": written_cs
                }),
                Vec::new(),
            ))
        }
        "close" => {
            if let Some(sid) = params["session"].as_str() {
                state.sessions.remove(sid);
            }
            Ok((json!({}), Vec::new()))
        }
        other => bail!("unsupported method: {other}"),
    }
}

fn write_frame(out: &mut impl Write, header: &Value, payload: &[u8]) -> Result<()> {
    let hbytes = serde_json::to_vec(header)?;
    out.write_all(&(hbytes.len() as u32).to_le_bytes())?;
    out.write_all(&(payload.len() as u32).to_le_bytes())?;
    out.write_all(&hbytes)?;
    out.write_all(payload)?;
    out.flush()?;
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mut resources = PathBuf::from("engine");
    let mut log_level = "error".to_string();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--resources" if i + 1 < args.len() => {
                resources = PathBuf::from(&args[i + 1]);
                i += 2;
            }
            "--log-level" if i + 1 < args.len() => {
                log_level = args[i + 1].clone();
                i += 2;
            }
            _ => {
                i += 1;
            }
        }
    }

    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(log_level)),
        )
        .init();

    let srgb_icc = std::fs::read(resources.join("io").join("sRGB.icc")).unwrap_or_default();
    let prophoto_icc = std::fs::read(resources.join("io").join("ProPhoto.icc")).unwrap_or_default();
    let backend = spektrafilm_gpu::select_backend();

    let mut state = HostState {
        data_dir: resources,
        backend,
        srgb_icc,
        prophoto_icc,
        sessions: HashMap::new(),
        next_session: 0,
    };

    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = BufWriter::new(stdout.lock());

    loop {
        let mut prefix = [0u8; 8];
        if let Err(e) = reader.read_exact(&mut prefix) {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                break;
            }
            return Err(e.into());
        }
        let hlen = u32::from_le_bytes([prefix[0], prefix[1], prefix[2], prefix[3]]) as usize;
        let plen = u32::from_le_bytes([prefix[4], prefix[5], prefix[6], prefix[7]]) as usize;
        if hlen > 16 * 1024 * 1024 || plen > 600 * 1024 * 1024 {
            bail!("frame too large: header={hlen}, payload={plen}");
        }
        let mut hbuf = vec![0u8; hlen];
        reader.read_exact(&mut hbuf)?;
        let mut pbuf = vec![0u8; plen];
        if plen > 0 {
            reader.read_exact(&mut pbuf)?;
        }

        let req: Value = serde_json::from_slice(&hbuf)?;
        let id = req.get("id").cloned().unwrap_or(Value::Null);
        let method = req["method"].as_str().unwrap_or("");
        let params = req.get("params").cloned().unwrap_or_else(|| json!({}));

        if method == "shutdown" {
            let resp = json!({ "id": id, "ok": true, "result": {} });
            write_frame(&mut writer, &resp, &[])?;
            break;
        }

        match handle_request(&mut state, method, params) {
            Ok((res, payload)) => {
                let resp = json!({ "id": id, "ok": true, "result": res });
                write_frame(&mut writer, &resp, &payload)?;
            }
            Err(err) => {
                let resp = json!({
                    "id": id,
                    "ok": false,
                    "error": { "code": "engine_error", "message": err.to_string() }
                });
                write_frame(&mut writer, &resp, &[])?;
            }
        }
    }

    Ok(())
}
