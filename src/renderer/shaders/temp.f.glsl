#version 430 core

layout(binding = 0, std140) uniform Globals
{
    vec3 iResolution;
    float iTime;
    float iTimeDelta;
    float iFrameRate;
    int iFrame;
    float iChannelTime[4];
    vec3 iChannelResolution[4];
    vec4 iMouse;
    vec4 iDate;
    float iSampleRate;
} _89;

layout(binding = 1) uniform sampler2D iChannel0;

layout(location = 0) out vec4 _fragColor;

void main() {
    // red
    _fragColor = vec4(_89.iSampleRate, 0.0, 0.0, 1.0);

    // maze
    //vec4 I = gl_FragCoord;
    //_fragColor = vec4(3)*modf(I*.1,I)[int(length(I)*1e4)&1];
}
