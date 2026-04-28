resource "aws_ebs_volume" "pangolin" {
  availability_zone = "eu-west-2a"
  size              = 1

  tags = {
    PangolinSnapshot = "true"
  }

}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "dlm_lifecycle_role" {
  name               = "dlm-lifecycle-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "dlm_lifecycle" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:CreateSnapshot",
      "ec2:CreateSnapshots",
      "ec2:DeleteSnapshot",
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
    ]

    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*::snapshot/*"]
  }
}

resource "aws_iam_role_policy" "dlm_lifecycle" {
  name   = "dlm-lifecycle-policy"
  role   = aws_iam_role.dlm_lifecycle_role.id
  policy = data.aws_iam_policy_document.dlm_lifecycle.json
}

resource "aws_dlm_lifecycle_policy" "pangolin_snapshots" {
  description        = "Pangolin Volume DLM lifecycle policy"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    policy_type = "EBS_SNAPSHOT_MANAGEMENT"

    schedule {
      name = "Every Saturday at 04 AM UTC"

      create_rule {
        cron_expression = "cron(0 4 ? * SAT *)"
      }

      retain_rule {
        count = 5
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = false
    }

    target_tags = {
      PangolinSnapshot = "true"
    }
  }
}
