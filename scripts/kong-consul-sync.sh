#!/bin/bash

# Kong-Consul 服务发现同步脚本
# 从 Consul 获取服务信息并在 Kong 中创建对应的服务和路由

CONSUL_URL="http://192.168.5.158:8500"
KONG_ADMIN_URL="http://192.168.5.159:8001"

echo "🔍 Kong-Consul 服务发现同步工具"
echo "Consul URL: $CONSUL_URL"
echo "Kong Admin URL: $KONG_ADMIN_URL"

# 检查连接性
check_connectivity() {
    echo "📡 检查连接性..."
    
    if ! curl -s "$CONSUL_URL/v1/status/leader" > /dev/null; then
        echo "❌ 无法连接到 Consul"
        exit 1
    fi
    
    if ! curl -s "$KONG_ADMIN_URL/" > /dev/null; then
        echo "❌ 无法连接到 Kong Admin API"
        exit 1
    fi
    
    echo "✅ 连接性检查通过"
}

# 从 Consul 获取服务列表
get_consul_services() {
    echo "📋 获取 Consul 服务列表..."
    curl -s "$CONSUL_URL/v1/agent/services" | jq -r 'keys[]' 2>/dev/null || echo ""
}

# 获取服务详细信息
get_service_details() {
    local service_name="$1"
    curl -s "$CONSUL_URL/v1/agent/services" | jq -r ".\"$service_name\"" 2>/dev/null
}

# 在 Kong 中创建服务
create_kong_service() {
    local service_name="$1"
    local service_host="$2"
    local service_port="$3"
    
    echo "🔧 创建 Kong 服务: $service_name"
    
    # 检查服务是否已存在
    if curl -s "$KONG_ADMIN_URL/services/$service_name" | jq -e '.id' > /dev/null 2>&1; then
        echo "⚠️  服务 $service_name 已存在，跳过创建"
        return 0
    fi
    
    # 创建服务
    curl -s -X POST "$KONG_ADMIN_URL/services" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$service_name\",
            \"protocol\": \"http\",
            \"host\": \"$service_host\",
            \"port\": $service_port,
            \"path\": \"/\"
        }" | jq '.id' > /dev/null
    
    if [ $? -eq 0 ]; then
        echo "✅ 服务 $service_name 创建成功"
        create_kong_route "$service_name"
    else
        echo "❌ 服务 $service_name 创建失败"
    fi
}

# 在 Kong 中创建路由
create_kong_route() {
    local service_name="$1"
    local route_name="${service_name}-route"
    
    echo "🛣️  创建 Kong 路由: $route_name"
    
    # 检查路由是否已存在
    if curl -s "$KONG_ADMIN_URL/routes" | jq -e ".data[] | select(.name == \"$route_name\")" > /dev/null 2>&1; then
        echo "⚠️  路由 $route_name 已存在，跳过创建"
        return 0
    fi
    
    # 创建路由
    curl -s -X POST "$KONG_ADMIN_URL/services/$service_name/routes" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$route_name\",
            \"paths\": [\"/$service_name\"],
            \"methods\": [\"GET\", \"POST\", \"PUT\", \"DELETE\"],
            \"strip_path\": true
        }" | jq '.id' > /dev/null
    
    if [ $? -eq 0 ]; then
        echo "✅ 路由 $route_name 创建成功"
    else
        echo "❌ 路由 $route_name 创建失败"
    fi
}

# 主同步函数
sync_services() {
    echo "🔄 开始同步服务..."
    
    # 手动定义一些已知服务进行测试
    declare -A services
    services["n8n"]="n8n.n8n.svc.cluster.local:5678"
    services["minio"]="minio.minio.svc.cluster.local:9000"
    services["consul-ui"]="consul-ui.consul.svc.cluster.local:8500"
    
    for service_name in "${!services[@]}"; do
        IFS=':' read -r host port <<< "${services[$service_name]}"
        echo "📦 处理服务: $service_name ($host:$port)"
        create_kong_service "$service_name" "$host" "$port"
    done
}

# 列出 Kong 中的服务
list_kong_services() {
    echo "📊 Kong 中的服务列表:"
    curl -s "$KONG_ADMIN_URL/services" | jq -r '.data[] | "- \(.name): \(.protocol)://\(.host):\(.port)"' 2>/dev/null || echo "获取失败"
}

# 主程序
main() {
    check_connectivity
    sync_services
    echo ""
    list_kong_services
    echo ""
    echo "🎉 同步完成！"
    echo "💡 测试访问: curl http://192.168.5.157/n8n"
}

# 运行主程序
main "$@"