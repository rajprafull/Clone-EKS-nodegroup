Steps:

1. Download file using below command:

       curl -fsSLO https://raw.githubusercontent.com/rajprafull/Clone-EKS-nodegroup/main/clone.sh
  
2. Change permission of file:
   
       chmod +x clone.sh

3. Run below command to make clone of existing EKS nodegroup: 

       ./clone.sh --region <region-code>
