/// The size of the simulation domain relative to a reference size, per axis.
///
/// The fluid grid, the noise and the per-line noise are all scaled by this, so
/// a fluid cell and a noise feature cover the same logical area on every
/// screen and stay square whatever its shape or orientation. (A fixed-size
/// square grid stretched over the screen made the flow run sideways on
/// landscape screens and vertically on portrait ones.)
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScalingRatio {
    x: f32,
    y: f32,
}

impl ScalingRatio {
    /// The logical size at which the ratio is 1: the geometric mean of a
    /// 2560×1440 screen, so that size keeps the original fluid cell area.
    const REFERENCE_SIZE: f32 = 1920.0;

    pub fn new(width: u32, height: u32) -> Self {
        Self {
            x: width as f32 / Self::REFERENCE_SIZE,
            y: height as f32 / Self::REFERENCE_SIZE,
        }
    }

    pub fn x(&self) -> f32 {
        self.x
    }

    pub fn y(&self) -> f32 {
        self.y
    }

    /// `base` scaled per axis and rounded to a multiple of 16, the compute
    /// workgroup size.
    pub fn scale(&self, base: u32) -> (u32, u32) {
        let scale_axis = |ratio: f32| (base as f32 * ratio / 16.0).round().max(1.0) as u32 * 16;
        (scale_axis(self.x), scale_axis(self.y))
    }
}

pub struct Grid {
    pub width: u32,
    pub height: u32,
    pub aspect_ratio: f32,
    pub columns: u32,
    pub rows: u32,
    pub line_count: u32,
    pub scaling_ratio: ScalingRatio,
    pub basepoints: Vec<f32>,
}

impl Grid {
    pub fn new(uwidth: u32, uheight: u32, grid_spacing: u32) -> Self {
        let height = uheight as f32;
        let width = uwidth as f32;
        let aspect_ratio = width / height;
        let grid_spacing = grid_spacing as f32;

        let columns = f32::floor(width / grid_spacing);
        let rows = f32::floor((height / width) * columns);
        let grid_spacing_x: f32 = 1.0 / columns;
        let grid_spacing_y: f32 = 1.0 / rows;

        let columns = columns as u32 + 1;
        let rows = rows as u32 + 1;
        let line_count = rows * columns;
        let scaling_ratio = ScalingRatio::new(uwidth, uheight);

        let mut basepoints = Vec::with_capacity(2 * line_count as usize);

        for v in 0..rows {
            for u in 0..columns {
                basepoints.push(u as f32 * grid_spacing_x);
                basepoints.push(v as f32 * grid_spacing_y);
            }
        }

        Self {
            width: uwidth,
            height: uheight,
            aspect_ratio,
            columns,
            rows,
            scaling_ratio,
            line_count,
            basepoints,
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    fn clamp_logical_size(width: u32, height: u32) -> (u32, u32) {
        let width = width as f32;
        let height = height as f32;

        // TODO: Should we also clamp the upper bound?
        let minimum_dimension = 800.0;
        let scale = f32::max(minimum_dimension / width, minimum_dimension / height).max(1.0);
        (
            (width * scale).floor() as u32,
            (height * scale).floor() as u32,
        )
    }

    #[derive(Copy, Clone, PartialEq, Debug)]
    struct LogicalSize {
        pub width: u32,
        pub height: u32,
    }

    impl LogicalSize {
        pub fn new(width: u32, height: u32) -> Self {
            Self { width, height }
        }
    }

    fn create_test_grid(logical_size: LogicalSize, grid_spacing: u32) -> (u32, u32) {
        let Grid { columns, rows, .. } =
            Grid::new(logical_size.width, logical_size.height, grid_spacing);
        (columns, rows)
    }

    #[test]
    fn is_sane_grid_for_iphone_xr() {
        let logical_size = LogicalSize::new(414, 896);
        assert_eq!(create_test_grid(logical_size, 15), (28, 59));
        assert_eq!(
            clamp_logical_size(logical_size.width, logical_size.height),
            (800, 1731)
        );
    }

    #[test]
    fn is_sane_grid_for_iphone_12_pro() {
        let logical_size = LogicalSize::new(390, 844);
        assert_eq!(create_test_grid(logical_size, 15), (27, 57));
        assert_eq!(
            clamp_logical_size(logical_size.width, logical_size.height),
            (800, 1731)
        );
    }

    #[test]
    fn is_sane_grid_for_macbook_pro_13_with_1280_800_scaling() {
        let logical_size = LogicalSize::new(1280, 800);
        assert_eq!(create_test_grid(logical_size, 15), (86, 54));
        assert_eq!(
            clamp_logical_size(logical_size.width, logical_size.height),
            (1280, 800)
        );
    }

    #[test]
    fn is_sane_grid_for_macbook_pro_15_with_1440_900_scaling() {
        let logical_size = LogicalSize::new(1440, 900);
        assert_eq!(create_test_grid(logical_size, 15), (97, 61));
        assert_eq!(
            clamp_logical_size(logical_size.width, logical_size.height),
            (1440, 900)
        );
    }

    #[test]
    fn is_sane_grid_for_ultrawide_4k() {
        let logical_size = LogicalSize::new(3840, 1600);
        assert_eq!(create_test_grid(logical_size, 15), (257, 107));
        assert_eq!(
            clamp_logical_size(logical_size.width, logical_size.height),
            (3840, 1600)
        );
    }

    #[test]
    fn is_sane_grid_for_triple_2560_1440() {
        let logical_size = LogicalSize::new(2560 * 3, 1440);
        assert_eq!(create_test_grid(logical_size, 15), (513, 97));
        assert_eq!(
            clamp_logical_size(logical_size.width, logical_size.height),
            (logical_size.width, logical_size.height)
        );
    }
}
