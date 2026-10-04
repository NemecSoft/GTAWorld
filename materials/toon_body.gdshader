shader_type spatial;

// #28 写实→卡通：硬色阶 + 阴影染色 + 边缘光。
// 骨架照抄工作区 ref/GodotVehicle/Material/Paint/Toon.gdshader 的 light()，
// 三处为「穿在人物身上」而改：
//   1) 去掉车漆专用的 pattern（那套要一张阴影形状贴图，人物用不上）
//   2) albedo 走纯色——素体拆包时皮肤贴图就缺了，采样空贴图会渲成黑
//   3) 补一项 fill_light 底光——本文件只写 DIFFUSE_LIGHT、不吃环境光，
//      不补的话背光面会纯黑一片

uniform vec4 skin_color : source_color = vec4(0.82, 0.62, 0.52, 1.0);
uniform float steps : hint_range(1.0, 8.0, 1.0) = 3.0;
uniform float step_smoothness : hint_range(0.0, 0.5, 0.01) = 0.18;
uniform vec4 shadow_tint : source_color = vec4(0.30, 0.20, 0.32, 1.0);
uniform float shadow_tint_amount : hint_range(0.0, 1.0, 0.05) = 0.45;
uniform float fill_light : hint_range(0.0, 1.0, 0.05) = 0.30;
uniform float rim_amount : hint_range(0.5, 8.0, 0.1) = 2.6;
uniform float rim_blend : hint_range(0.0, 1.0, 0.05) = 0.22;
uniform vec4 rim_color : source_color = vec4(1.0, 0.96, 0.88, 1.0);


float fresnel(float amount, vec3 normal, vec3 view) {
	return pow(clamp(1.0 - dot(normalize(normal), normalize(view)), 0.0, 1.0), amount);
}


void fragment() {
	ALBEDO = skin_color.rgb;
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}


void light() {
	float ndotl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION;

	// 量化成 N 档，档间用 smoothstep 收一下边（smoothness=0 就是硬边）
	float mult = ndotl * steps;
	float base = floor(mult);
	float f = mult - base;
	f = smoothstep(0.5 - step_smoothness, 0.5 + step_smoothness, f);
	float band = (base + f) / steps;

	vec3 diffuse = vec3(band) * (LIGHT_COLOR / PI) * ALBEDO;
	diffuse += shadow_tint.rgb * ALBEDO * (1.0 - band) * shadow_tint_amount;
	diffuse += ALBEDO * fill_light;

	float rim = smoothstep(0.4, 0.6, fresnel(rim_amount, NORMAL, VIEW));
	diffuse += rim_color.rgb * rim * rim_blend * (0.35 + 0.65 * band);

	DIFFUSE_LIGHT += diffuse;
	SPECULAR_LIGHT += vec3(0.0);
}
