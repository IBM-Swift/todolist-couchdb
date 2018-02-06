#!/bin/bash
#------------------------------------------------------------
# Script: config.sh
# Author: Swift@IBM
# -----------------------------------------------------------

set -e

VERSION="1.0"
BUILD_DIR=".build-linux"
BRIDGE_APP_NAME="containerbridge"
DATABASE_NAME="TodoListCloudantDatabase"
REGISTRY_URL="registry.ng.bluemix.net"
DATABASE_TYPE="cloudantNoSQLDB"
DATABASE_LEVEL="Lite"
INSTANCE_NAME="todolist-couchdb"
NAME_SPACE="todolist_space"
LOGIN_URL="api.ng.bluemix.net"

function help {
    cat <<-!!EOF
    Usage: $CMD [ build | run | push-docker ] [arguments...]
    Where:
    install_tools                                               Installs necessary tools for config, like Cloud Foundry CLI
    login                                                       Logs into Bluemix and Container APIs
    setup <clusterName> <nameSpace>                             Sets up the clusters
    build <dockerName>                                          Builds Docker container from Dockerfile
    run <dockerName>                                            Runs Docker container, ensuring it was built properly
    stop <dockerName>                                           Stops Docker container, if running
    push <dockerName> <nameSpace>                               Tags and pushes Docker container to IBM Cloud
    create_db <clusterName> <instanceName>                      Creates database service
    get_ip <clusterName>                                        Get the public IP
    deploy <appName>                                            Exposes the deployment
    populate_db <appURL>                                        Populates database with initial data
    delete <clusterName> <instanceName> <nameSpace>             Delete the created service and cluster if possible
    all <clusterName> <instanceName> <dockerName> <nameSpace>   Combines all necessary commands to deploy an app to IBM Cloud in a Docker container.
!!EOF
}

install_tools () {
    curl -sL https://ibm.biz/idt-installer | bash
    bx plugin install container-service -r Bluemix
}

login () {
    echo "Setting api and login tools."
    bx login --sso -a $LOGIN_URL
    bx target --cf
}

setup () {
    if [ -z "$1" ] || [ -z "$2" ]
    then
        echo "Error: setup failed, cluster name, and name space not provided."
        return
    fi

    bx cr login

    if bx cs cluster-get $1 | grep specified
    then
        echo "Attempting to create new cluster..."
        bx cs cluster-create --name $1

        until bx cs cluster-get $1 | grep pending
        do
            sleep 60
            bx cs cluster-get $1
            echo "Cluster still provisioning..."
        done
        echo "Cluster deployed successfully."
    fi

    bx cr namespace-add $2
    bx cs workers $1
    bx cs cluster-config $1 --export
    datacenter=$(bx cs cluster-get $1 | grep Datacenter | awk '{ print $NF }')
    export KUBECONFIG=$HOME/.bluemix/plugins/container-service/clusters/$1/kube-config-$datacenter-$1.yml
}

build_docker () {
    if [ -z "$1" ]
    then
        echo "Error: run failed, docker name not provided."
        return
    fi

    docker build -t $1 .
}

run_docker () {
    if [ -z "$1" ]
    then
        echo "Error: run failed, docker name not provided."
        return
    fi

    sudo docker run --name $1 -d -p 8080:8080 $1
}

stop_docker () {
    if [ -z "$1" ]
    then
        echo "Error: clean failed, docker name not provided."
        return
    fi

    docker rm -fv $1 || true
}

push_docker () {
    if [ -z "$1" ] || [ -z "$2" ]
    then
        echo "Error: clean failed, docker name, and name space not provided."
        return
    fi

    docker tag $1 $REGISTRY_URL/$2/$1
    docker push $REGISTRY_URL/$2/$1
    docker ps
    bx cr images
}

create_database () {
    if [ -z "$1" ] || [ -z "$2" ]
    then
        echo "Error: Creating database failed, cluster name, and service name not provided."
        return
    fi

    kubectl apply -f manifest.yml
    bx service create cloudantNoSQLDB Lite $2
    bx cs cluster-service-bind $1 default $2
}

deploy_container () {
    if [ -z "$1" ]
    then
        echo "Error: Deploying container failed, app name not provided."
        return
    fi

    ip_addr=$(bx cs workers $1 | awk '{ print $2 }' | sed 's/.*:\([0-9]*\).*/\1/g' | tr -d 'Public')
    lowercase="$(tr [A-Z] [a-z] <<< "$1")"
    nodashes="$(tr -d '-' <<< "$lowercase")"
    kubectl expose deployment/$1 --type=NodePort --external-ip=$ip_addr --name=$1 --port=8080
}

get_ip () {
    if [ -z "$1" ]
    then
        echo "Error: Getting IP failed, cluster name not provided."
        return
    fi

    ip_addr=$(bx cs workers $1 | awk '{ print $2 }' | sed 's/.*:\([0-9]*\).*/\1/g' | tr -d 'Public')
    port=$(kubectl get services | grep $1 | awk '{ print $5 }' | sed 's/.*:\([0-9]*\).*/\1/g')
    echo "You may view the application at: http://$ip_addr:$port" | tr -d '\n'
    echo ""
}

populate_db () {
    if [ -z "$1" ]
    then
        echo "Error: Could not populate db with sample data. App URL not provided."
        return
    fi

    curl -v -H "Content-Type: application/json" -d '{"title":"Wash the car","order":0,"completed":false}' $1
    curl -v -H "Content-Type: application/json" -d '{ "title": "Walk the dog", "order": 2, "completed": true }' $1
    curl -v -H "Content-Type: application/json" -d '{ "title": "Clean the gutters", "order": 1, "completed": false }' $1

    echo "Populated the database with sample data"
}

delete () {
    if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]
    then
        echo "Error: Could not delete container group and service, cluster name, service instance name, and name space not provided."
        return
    fi

    bx cs cluster-service-unbind $1 $3 $2
    bx service key-delete $2 "kube-$2"
    bx service delete $2
    kubectl delete services $2
    kubectl delete deployment $1
    bx cs cluster-rm $1
}

all () {
    if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]
    then
        echo "Error: Could not complete entire deployment process, cluster name, service instance name, docker name, and name space not provided."
        return
    fi

    install_tools
    login
    setup $1 $4
    build_docker $3
    push_docker $3 $4
    create_database $1 $2
    deploy_container $1 $3 $4
    get_ip $1
}

#----------------------------------------------------------
# MAIN
# ---------------------------------------------------------

ACTION="$1"

[[ -z $ACTION ]] && help && exit 0

# Initialize the SwiftEnv project environment
eval "$(swiftenv init -)"


case $ACTION in
"install_tools")         install_tools;;
"login")                 login;;
"setup")                 setup "$2" "$3";;
"build")                 build_docker "$2";;
"run")                   run_docker "$2";;
"stop")                  stop_docker "$2";;
"push")                  push_docker "$2" "$3";;
"create_db")             create_database "$2" "$3";;
"get_ip")                get_ip "$2";;
"deploy")                deploy_container "$2" "$3" "$4";;
"populate_db")           populate_db "$2";;
"delete")                delete "$2" "$3" "$4";;
"all")                   all "$2" "$3" "$4" "$5";;
*)                       help;;
esac
