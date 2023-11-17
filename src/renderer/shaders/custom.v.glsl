#version 330 core

void main(){
    vec2 position;
    position.x = (gl_VertexID == 0 || gl_VertexID == 1) ? 1. : 0.;
    position.y = (gl_VertexID == 0 || gl_VertexID == 3) ? 0. : 1.;
    gl_Position = vec4(position.xy, 0.0f, 1.0f);
}
