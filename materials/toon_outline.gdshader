shader_type spatial;

// #28 描边（反壳 / inverted hull）：把网格沿法线外扩一圈、只画背面，
// 于是从外面看就是一圈黑色剪影。Godot 4.7 的 StandardMaterial3D 没有
// outline_enabled 这个开关（本机实测，见 Temp/mat_probe_report.txt），只能自己写。
//
// 注意 thickness 是「模型局部单位」，会被 _model 的 fit 缩放（约 38 倍）放大，
// 所以由 GDScript 按世界毫米数换算后塞进来，别在这里填大数。

render_mode cull_front, unshaded;

uniform vec4 outline_color : source_color = vec4(0.06, 0.04, 0.07, 1.0);
uniform float thickness = 0.0004;
// 掠射裁剪：只留「快侧对镜头」的那一圈。整块背面在四肢之间的空档里会露出来
// （肩窝、胯缝那类大黑斑），把 |N·V| 大于阈值的片元丢掉，黑斑就退化成细线。
// 1.0 = 不裁剪（能看到完整背面）。
uniform float grazing_cut : hint_range(0.1, 1.0, 0.01) = 0.75;


void vertex() {
	VERTEX += normalize(NORMAL) * thickness;
}


void fragment() {
	if (abs(dot(normalize(NORMAL), VIEW)) > grazing_cut) {
		discard;
	}
	ALBEDO = outline_color.rgb;
}
