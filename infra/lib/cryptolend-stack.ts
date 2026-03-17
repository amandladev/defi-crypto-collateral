import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as ecsPatterns from "aws-cdk-lib/aws-ecs-patterns";
import * as rds from "aws-cdk-lib/aws-rds";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as events from "aws-cdk-lib/aws-events";
import * as eventsTargets from "aws-cdk-lib/aws-events-targets";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cloudwatchActions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as sns from "aws-cdk-lib/aws-sns";
import * as logs from "aws-cdk-lib/aws-logs";
import { Construct } from "constructs";

/**
 * CryptoLend Infrastructure Stack
 *
 * Architecture:
 * - VPC with public/private subnets
 * - ECS Fargate for API service
 * - ECS Fargate for Liquidation worker
 * - RDS PostgreSQL for persistence
 * - SQS for liquidation event queue
 * - EventBridge for price update events
 * - CloudWatch alarms for monitoring
 */
export class CryptoLendStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ════════════════════════════════════════════════════════════════
    // VPC
    // ════════════════════════════════════════════════════════════════
    const vpc = new ec2.Vpc(this, "CryptoLendVpc", {
      maxAzs: 2,
      natGateways: 1,
      subnetConfiguration: [
        {
          name: "Public",
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
        {
          name: "Private",
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask: 24,
        },
        {
          name: "Isolated",
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
          cidrMask: 24,
        },
      ],
    });

    // ════════════════════════════════════════════════════════════════
    // RDS PostgreSQL
    // ════════════════════════════════════════════════════════════════
    const dbSecurityGroup = new ec2.SecurityGroup(this, "DbSG", {
      vpc,
      description: "Security group for CryptoLend RDS",
      allowAllOutbound: false,
    });

    const database = new rds.DatabaseInstance(this, "CryptoLendDb", {
      engine: rds.DatabaseInstanceEngine.postgres({
        version: rds.PostgresEngineVersion.VER_15,
      }),
      instanceType: ec2.InstanceType.of(
        ec2.InstanceClass.T3,
        ec2.InstanceSize.MICRO
      ),
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      securityGroups: [dbSecurityGroup],
      databaseName: "cryptolend",
      credentials: rds.Credentials.fromGeneratedSecret("cryptolend_admin"),
      multiAz: false, // MVP: single AZ
      allocatedStorage: 20,
      storageEncrypted: true,
      backupRetention: cdk.Duration.days(7),
      deletionProtection: false, // Set true in production
      removalPolicy: cdk.RemovalPolicy.DESTROY, // MVP only
    });

    // ════════════════════════════════════════════════════════════════
    // SQS Queues
    // ════════════════════════════════════════════════════════════════
    const liquidationDLQ = new sqs.Queue(this, "LiquidationDLQ", {
      queueName: "cryptolend-liquidation-dlq",
      retentionPeriod: cdk.Duration.days(14),
    });

    const liquidationQueue = new sqs.Queue(this, "LiquidationQueue", {
      queueName: "cryptolend-liquidation",
      visibilityTimeout: cdk.Duration.minutes(5),
      deadLetterQueue: {
        queue: liquidationDLQ,
        maxReceiveCount: 3,
      },
    });

    const priceUpdateQueue = new sqs.Queue(this, "PriceUpdateQueue", {
      queueName: "cryptolend-price-updates",
      visibilityTimeout: cdk.Duration.seconds(30),
    });

    // ════════════════════════════════════════════════════════════════
    // EventBridge
    // ════════════════════════════════════════════════════════════════
    const eventBus = new events.EventBus(this, "CryptoLendBus", {
      eventBusName: "cryptolend-events",
    });

    // Route price updates to SQS
    new events.Rule(this, "PriceUpdateRule", {
      eventBus,
      eventPattern: {
        source: ["cryptolend.oracle"],
        detailType: ["PriceUpdate"],
      },
      targets: [new eventsTargets.SqsQueue(priceUpdateQueue)],
    });

    // Route liquidation triggers to SQS
    new events.Rule(this, "LiquidationRule", {
      eventBus,
      eventPattern: {
        source: ["cryptolend.risk"],
        detailType: ["LiquidationRequired"],
      },
      targets: [new eventsTargets.SqsQueue(liquidationQueue)],
    });

    // ════════════════════════════════════════════════════════════════
    // ECS Cluster
    // ════════════════════════════════════════════════════════════════
    const cluster = new ecs.Cluster(this, "CryptoLendCluster", {
      vpc,
      containerInsights: true,
    });

    // ════════════════════════════════════════════════════════════════
    // API Service (Fargate + ALB)
    // ════════════════════════════════════════════════════════════════
    const apiService =
      new ecsPatterns.ApplicationLoadBalancedFargateService(
        this,
        "ApiService",
        {
          cluster,
          cpu: 256,
          memoryLimitMiB: 512,
          desiredCount: 2,
          taskImageOptions: {
            image: ecs.ContainerImage.fromAsset(".."),
            containerPort: 8080,
            environment: {
              PORT: "8080",
              MAX_LTV: "0.50",
              LIQUIDATION_THRESHOLD: "0.70",
              LIQUIDATION_PENALTY: "0.10",
              ORACLE_POLL_INTERVAL_SEC: "30",
              LIQUIDATION_POLL_INTERVAL_SEC: "10",
            },
            secrets: {
              DATABASE_URL: ecs.Secret.fromSecretsManager(
                database.secret!,
                "host"
              ),
            },
            logDriver: ecs.LogDrivers.awsLogs({
              streamPrefix: "cryptolend-api",
              logRetention: logs.RetentionDays.ONE_MONTH,
            }),
          },
          publicLoadBalancer: true,
        }
      );

    // Allow API to connect to RDS
    database.connections.allowFrom(
      apiService.service,
      ec2.Port.tcp(5432),
      "API to RDS"
    );

    // Grant SQS access
    liquidationQueue.grantSendMessages(apiService.taskDefinition.taskRole);

    // ════════════════════════════════════════════════════════════════
    // Liquidation Worker (Fargate Service — no ALB)
    // ════════════════════════════════════════════════════════════════
    const liquidatorTaskDef = new ecs.FargateTaskDefinition(
      this,
      "LiquidatorTask",
      {
        cpu: 256,
        memoryLimitMiB: 512,
      }
    );

    liquidatorTaskDef.addContainer("Liquidator", {
      image: ecs.ContainerImage.fromAsset(".."),
      command: ["./liquidator"],
      environment: {
        LIQUIDATION_POLL_INTERVAL_SEC: "10",
        ORACLE_POLL_INTERVAL_SEC: "15",
      },
      logging: ecs.LogDrivers.awsLogs({
        streamPrefix: "cryptolend-liquidator",
        logRetention: logs.RetentionDays.ONE_MONTH,
      }),
    });

    const liquidatorService = new ecs.FargateService(
      this,
      "LiquidatorService",
      {
        cluster,
        taskDefinition: liquidatorTaskDef,
        desiredCount: 1, // Single instance to avoid duplicate liquidations
        vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      }
    );

    database.connections.allowFrom(
      liquidatorService,
      ec2.Port.tcp(5432),
      "Liquidator to RDS"
    );
    liquidationQueue.grantConsumeMessages(liquidatorTaskDef.taskRole);

    // ════════════════════════════════════════════════════════════════
    // CloudWatch Alarms
    // ════════════════════════════════════════════════════════════════
    const alertTopic = new sns.Topic(this, "AlertTopic", {
      topicName: "cryptolend-alerts",
    });

    // DLQ alarm — any message in DLQ means a liquidation failed
    new cloudwatch.Alarm(this, "LiquidationDLQAlarm", {
      metric: liquidationDLQ.metricApproximateNumberOfMessagesVisible(),
      threshold: 1,
      evaluationPeriods: 1,
      alarmDescription: "Liquidation DLQ has messages — failed liquidations!",
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    }).addAlarmAction(new cloudwatchActions.SnsAction(alertTopic));

    // API 5xx errors
    new cloudwatch.Alarm(this, "Api5xxAlarm", {
      metric:
        apiService.loadBalancer.metrics.httpCodeTarget(
          cdk.aws_elasticloadbalancingv2.HttpCodeTarget.TARGET_5XX_COUNT,
          { period: cdk.Duration.minutes(5) }
        ),
      threshold: 10,
      evaluationPeriods: 2,
      alarmDescription: "High 5xx error rate on API",
    }).addAlarmAction(new cloudwatchActions.SnsAction(alertTopic));

    // DB CPU alarm
    new cloudwatch.Alarm(this, "DbCpuAlarm", {
      metric: database.metricCPUUtilization({
        period: cdk.Duration.minutes(5),
      }),
      threshold: 80,
      evaluationPeriods: 3,
      alarmDescription: "RDS CPU > 80%",
    }).addAlarmAction(new cloudwatchActions.SnsAction(alertTopic));

    // ════════════════════════════════════════════════════════════════
    // Outputs
    // ════════════════════════════════════════════════════════════════
    new cdk.CfnOutput(this, "ApiUrl", {
      value: apiService.loadBalancer.loadBalancerDnsName,
      description: "API Load Balancer URL",
    });

    new cdk.CfnOutput(this, "LiquidationQueueUrl", {
      value: liquidationQueue.queueUrl,
      description: "Liquidation SQS Queue URL",
    });

    new cdk.CfnOutput(this, "DatabaseEndpoint", {
      value: database.dbInstanceEndpointAddress,
      description: "RDS Endpoint",
    });
  }
}

// ── App entry point ──
const app = new cdk.App();
new CryptoLendStack(app, "CryptoLendStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || "us-east-1",
  },
});
