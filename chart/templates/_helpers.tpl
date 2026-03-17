{{- define "commonLabels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: "{{ .Chart.AppVersion }}"
app.kubernetes.io/part-of: {{.Chart.Name}}
app.kubernetes.io/component: {{ .Values.component | default "default" }}
{{- end -}}

{{- define "selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: {{.Chart.Name}}
app.kubernetes.io/component: {{ .Values.component | default "default"}}
{{- end -}}

