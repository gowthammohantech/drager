using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using SpatialBridge.App.Interop;

namespace SpatialBridge.App.Overlay;

/// <summary>
/// Borderless, topmost, click-through, never-activated Win32 popup (TD §8, FR-204, ADR-008) — the Windows
/// counterpart of the Mac's non-activating NSPanel. Content is a per-pixel-alpha 32-bit DIB pushed with
/// <c>UpdateLayeredWindow</c>; the process is per-monitor DPI v2, so all coordinates are physical pixels.
/// </summary>
internal sealed unsafe class LayeredOverlayWindow : IDisposable
{
    private const string ClassName = "SpatialBridge.ArrivalOverlay";
    private static bool s_classRegistered;

    private nint _hwnd;
    private nint _memoryDC;
    private nint _bitmap;
    private nint _previousBitmap;
    private void* _bits;
    private int _width;
    private int _height;
    private bool _visible;

    public int Width => _width;

    public int Height => _height;

    /// <summary>Premultiplied BGRA pixels, top-down, <see cref="Width"/> × 4 bytes per row.</summary>
    public nint Bits => (nint)_bits;

    public bool IsCreated => _hwnd != 0;

    public bool EnsureCreated()
    {
        if (_hwnd != 0)
        {
            return true;
        }
        var instance = Win32.GetModuleHandle(null);
        if (!s_classRegistered)
        {
            fixed (char* name = ClassName)
            {
                var wc = new WndClassEx
                {
                    cbSize = (uint)sizeof(WndClassEx),
                    lpfnWndProc = &WndProc,
                    hInstance = instance,
                    lpszClassName = name,
                };
                if (Win32.RegisterClassEx(&wc) == 0 && Marshal.GetLastPInvokeError() != 1410 /* ERROR_CLASS_ALREADY_EXISTS */)
                {
                    return false;
                }
            }
            s_classRegistered = true;
        }
        const int exStyle = Win32.WsExLayered | Win32.WsExTransparent | Win32.WsExNoActivate | Win32.WsExToolWindow | Win32.WsExTopmost;
        _hwnd = Win32.CreateWindowEx(exStyle, ClassName, "Spatial Bridge arrival", Win32.WsPopup, 0, 0, 1, 1, 0, 0, instance, 0);
        return _hwnd != 0;
    }

    /// <summary>Reallocates the backing DIB if the size changed. Returns false if GDI refuses.</summary>
    public bool EnsureSurface(int width, int height)
    {
        width = Math.Max(1, width);
        height = Math.Max(1, height);
        if (_bitmap != 0 && width == _width && height == _height)
        {
            return true;
        }
        ReleaseSurface();
        var screen = Win32.GetDC(0);
        try
        {
            _memoryDC = Win32.CreateCompatibleDC(screen);
            var info = new BitmapInfo
            {
                bmiHeader = new BitmapInfoHeader
                {
                    biSize = (uint)sizeof(BitmapInfoHeader),
                    biWidth = width,
                    biHeight = -height, // top-down
                    biPlanes = 1,
                    biBitCount = 32,
                    biCompression = 0,
                },
            };
            void* bits;
            _bitmap = Win32.CreateDIBSection(screen, &info, Win32.DibRgbColors, &bits, 0, 0);
            if (_bitmap == 0 || bits is null)
            {
                ReleaseSurface();
                return false;
            }
            _bits = bits;
            _previousBitmap = Win32.SelectObject(_memoryDC, _bitmap);
            _width = width;
            _height = height;
            return true;
        }
        finally
        {
            _ = Win32.ReleaseDC(0, screen);
        }
    }

    /// <summary>Pushes the current pixels at (<paramref name="x"/>, <paramref name="y"/>) with a whole-window alpha.</summary>
    public void Present(int x, int y, byte opacity)
    {
        if (_hwnd == 0 || _bitmap == 0)
        {
            return;
        }
        var destination = new Point32 { X = x, Y = y };
        var size = new Size32 { Cx = _width, Cy = _height };
        var source = default(Point32);
        var blend = new BlendFunction { BlendOp = Win32.AcSrcOver, SourceConstantAlpha = opacity, AlphaFormat = Win32.AcSrcAlpha };
        var screen = Win32.GetDC(0);
        try
        {
            Win32.UpdateLayeredWindow(_hwnd, screen, &destination, &size, _memoryDC, &source, 0, &blend, Win32.UlwAlpha);
        }
        finally
        {
            _ = Win32.ReleaseDC(0, screen);
        }
        if (!_visible)
        {
            Win32.ShowWindow(_hwnd, Win32.SwShowNoActivate);
            Win32.SetWindowPos(_hwnd, Win32.HwndTopmost, 0, 0, 0, 0, Win32.SwpNoMove | Win32.SwpNoSize | Win32.SwpNoActivate | Win32.SwpShowWindow);
            _visible = true;
        }
    }

    public void Hide()
    {
        if (_hwnd != 0 && _visible)
        {
            Win32.ShowWindow(_hwnd, Win32.SwHide);
        }
        _visible = false;
    }

    public void Dispose()
    {
        Hide();
        ReleaseSurface();
        if (_hwnd != 0)
        {
            Win32.DestroyWindow(_hwnd);
            _hwnd = 0;
        }
    }

    private void ReleaseSurface()
    {
        if (_memoryDC != 0)
        {
            if (_previousBitmap != 0)
            {
                Win32.SelectObject(_memoryDC, _previousBitmap);
                _previousBitmap = 0;
            }
            Win32.DeleteDC(_memoryDC);
            _memoryDC = 0;
        }
        if (_bitmap != 0)
        {
            Win32.DeleteObject(_bitmap);
            _bitmap = 0;
        }
        _bits = null;
        _width = _height = 0;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static nint WndProc(nint hwnd, uint message, nint wParam, nint lParam) => message switch
    {
        Win32.WmNcHitTest => Win32.HtTransparent,     // click-through
        Win32.WmMouseActivate => Win32.MaNoActivate,  // never take focus
        _ => Win32.DefWindowProc(hwnd, message, wParam, lParam),
    };
}
