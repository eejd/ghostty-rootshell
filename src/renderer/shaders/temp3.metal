#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Implementation of the GLSL mod() function, which is slightly different than Metal fmod()
template<typename Tx, typename Ty>
inline Tx mod(Tx x, Ty y)
{
    return x - y * floor(x / y);
}

struct Globals
{
    float3 iResolution;
    float iTime;
    float iTimeDelta;
    float iFrameRate;
    int iFrame;
    float4 iChannelTime[4];
    float3 iChannelResolution[4];
    float4 iMouse;
    float4 iDate;
    float iSampleRate;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

static inline __attribute__((always_inline))
float2 curve(thread float2& uv)
{
    uv = (uv - float2(0.5)) * 2.0;
    uv *= 1.10000002384185791015625;
    uv.x *= (1.0 + pow(abs(uv.y) / 5.0, 2.0));
    uv.y *= (1.0 + pow(abs(uv.x) / 4.0, 2.0));
    uv = (uv / float2(2.0)) + float2(0.5);
    uv = (uv * 0.920000016689300537109375) + float2(0.039999999105930328369140625);
    return uv;
}

static inline __attribute__((always_inline))
void mainImage(thread float4& fragColor, thread const float2& fragCoord, constant Globals& _89, texture2d<float> iChannel0, sampler iChannel0Smplr)
{
    float2 q = fragCoord / float2(_89.iResolution[0], _89.iResolution[1]);
    float2 uv = q;
    float2 param = uv;
    float2 _100 = curve(param);
    uv = _100;
    float3 oricol = iChannel0.sample(iChannel0Smplr, float2(q.x, q.y)).xyz;
    float x = ((sin((0.300000011920928955078125 * _89.iTime) + (uv.y * 21.0)) * sin((0.699999988079071044921875 * _89.iTime) + (uv.y * 29.0))) * sin((0.300000011920928955078125 + (0.3300000131130218505859375 * _89.iTime)) + (uv.y * 31.0))) * 0.001700000022538006305694580078125;
    float3 col;
    col.x = iChannel0.sample(iChannel0Smplr, float2((x + uv.x) + 0.001000000047497451305389404296875, uv.y + 0.001000000047497451305389404296875)).x + 0.0500000007450580596923828125;
    col.y = iChannel0.sample(iChannel0Smplr, float2((x + uv.x) + 0.0, uv.y - 0.00200000009499490261077880859375)).y + 0.0500000007450580596923828125;
    col.z = iChannel0.sample(iChannel0Smplr, float2((x + uv.x) - 0.00200000009499490261077880859375, uv.y + 0.0)).z + 0.0500000007450580596923828125;
    col.x += (0.07999999821186065673828125 * iChannel0.sample(iChannel0Smplr, ((float2(x + 0.02500000037252902984619140625, -0.02700000070035457611083984375) * 0.75) + float2(uv.x + 0.001000000047497451305389404296875, uv.y + 0.001000000047497451305389404296875))).x);
    col.y += (0.0500000007450580596923828125 * iChannel0.sample(iChannel0Smplr, ((float2(x + (-0.02199999988079071044921875), -0.0199999995529651641845703125) * 0.75) + float2(uv.x + 0.0, uv.y - 0.00200000009499490261077880859375))).y);
    col.z += (0.07999999821186065673828125 * iChannel0.sample(iChannel0Smplr, ((float2(x + (-0.0199999995529651641845703125), -0.017999999225139617919921875) * 0.75) + float2(uv.x - 0.00200000009499490261077880859375, uv.y + 0.0))).z);
    col = fast::clamp((col * 0.60000002384185791015625) + (((col * 0.4000000059604644775390625) * col) * 1.0), float3(0.0), float3(1.0));
    float vig = 0.0 + ((((16.0 * uv.x) * uv.y) * (1.0 - uv.x)) * (1.0 - uv.y));
    col *= float3(pow(vig, 0.300000011920928955078125));
    col *= float3(0.949999988079071044921875, 1.0499999523162841796875, 0.949999988079071044921875);
    col *= 2.7999999523162841796875;
    float scans = fast::clamp(0.3499999940395355224609375 + (0.3499999940395355224609375 * sin((3.5 * _89.iTime) + ((uv.y * _89.iResolution[1u]) * 1.5))), 0.0, 1.0);
    float s = pow(scans, 1.7000000476837158203125);
    col *= float3(0.4000000059604644775390625 + (0.699999988079071044921875 * s));
    col *= (1.0 + (0.00999999977648258209228515625 * sin(110.0 * _89.iTime)));
    bool _352 = uv.x < 0.0;
    bool _359;
    if (!_352)
    {
        _359 = uv.x > 1.0;
    }
    else
    {
        _359 = _352;
    }
    if (_359)
    {
        col *= 0.0;
    }
    bool _366 = uv.y < 0.0;
    bool _373;
    if (!_366)
    {
        _373 = uv.y > 1.0;
    }
    else
    {
        _373 = _366;
    }
    if (_373)
    {
        col *= 0.0;
    }
    col *= (float3(1.0) - (float3(fast::clamp((mod(fragCoord.x, 2.0) - 1.0) * 2.0, 0.0, 1.0)) * 0.64999997615814208984375));
    float comp = smoothstep(0.100000001490116119384765625, 0.89999997615814208984375, sin(_89.iTime));
    fragColor = float4(col, 1.0);
}

fragment main0_out main0(constant Globals& _89 [[buffer(0)]], texture2d<float> iChannel0 [[texture(0)]], sampler iChannel0Smplr [[sampler(0)]], float4 gl_FragCoord [[position]])
{
    constexpr sampler iChannel0Smplr(address::clamp_to_edge, filter::linear);

    main0_out out = {};
    float2 param_1 = gl_FragCoord.xy;
    float4 param;
    mainImage(param, param_1, _89, iChannel0, iChannel0Smplr);
    out._fragColor = param;
    return out;
}

