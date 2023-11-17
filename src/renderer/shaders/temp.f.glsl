#version 330 core

layout(location = 0) out vec4 out_FragColor;

void main() {
    // red
    //out_FragColor = vec4(1.0, 0.0, 0.0, 1.0);

    // maze
    vec4 I = gl_FragCoord;
    out_FragColor = vec4(3)*modf(I*.1,I)[int(length(I)*1e4)&1];
}
