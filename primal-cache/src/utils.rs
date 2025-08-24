pub fn log(s: String) {
    // return;
    eprintln!("{} [{}]  {}", 
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S.%6f"), 
        std::process::id(), 
        s);
}

#[macro_export]
macro_rules! log {
    // match: log!( "foo" )
    ($msg:expr) => {
        $crate::log(format!($msg))
    };
    // match: log!( "foo {} {}", a, b )
    ($fmt:expr, $($arg:tt)+) => {
        $crate::log(format!($fmt, $($arg)+))
    };
}

pub fn logerr<T>(e: T)
where
    T: std::fmt::Debug,
{
    log!("{e:?}");
}

pub fn loge<T, R>(res: R) -> impl Fn(T) -> R
where
    T: std::fmt::Debug,
    R: std::clone::Clone
{
    move |e: T| {
        log!("{e:?}");
        res.clone()
    }
}

pub trait ResultLogErr<T, E, R> {
    fn map_log_err(self, r: R) -> Result<T, R>;
}

impl<T, E, R> ResultLogErr<T, E, R> for Result<T, E>
where
    E: std::fmt::Debug,
    R: std::clone::Clone
{
    fn map_log_err(self, r: R) -> Result<T, R> {
        self.map_err(|e| {
            log!("{e:?}");
            r
        })
    }
}


