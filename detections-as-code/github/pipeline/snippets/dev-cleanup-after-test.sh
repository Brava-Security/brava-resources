# "Delete the rule from Dev after testing", right after stage 3: https://docs.brava.security/hygiene/detection-as-code/
# Not a script: paste inside the loop of the dev job in detections-deploy.yml, after the case ... esac block.
# Exit 3: the local wait timed out and the test is still running, so keep the rule.
if [ "$rc" -ne 3 ]; then
  sx rule delete --id "$rule_id" --force > /dev/null \
    || echo "::warning file=$file::could not delete $name from Dev"
fi
